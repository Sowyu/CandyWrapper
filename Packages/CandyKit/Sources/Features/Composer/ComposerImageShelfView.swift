import AppKit
import DesignSystem
import T3Protocol

/// An image drawn from a loader that decodes off the main thread at display size (`object-cover`
/// by default). Nothing is decoded until the view sits in a window with a size, and a view that
/// leaves its window lets go of its pixels. A `cacheable` view keeps its decode in `memory`, so the
/// same image drawn again, say after switching threads and back, shows in the same frame.
public final class AsyncImageView: DSView {
    /// Decodes for a pixel side, with larger requests when the display grows.
    public typealias Loader = @Sendable (_ side: Int) async -> CGImage?
    public private(set) var key: String?
    private(set) var loader: Loader?
    private var failureText = ""
    private var pendingText = ""
    private var failed = false
    private var task: Task<Void, Never>?
    public var cover = true {
        didSet {
            guard cover != oldValue else { return }
            layer?.contentsGravity = cover ? .resizeAspectFill : .resizeAspect
            reset(); start()
        }
    }
    /// Shown until the image arrives or when it fails (`fallback`).
    public let fallback = LabelView("", font: DSFont.ui(10), color: Themed.color(\.secondaryLabel))
    public private(set) var image: CGImage?
    public var onLoad: (() -> Void)?
    public var onContextMenu: ((NSEvent, NSView) -> Void)?
    public override func rightMouseDown(with event: NSEvent) { onContextMenu?(event, self) }
    /// The pixel side to decode at; by default the view's own size at the screen's scale.
    public var requestedSide: Int? { didSet { if requestedSide != oldValue { start() } } }
    /// Set when `key` always names the same pixels, like a sent attachment's id or a draft copy's
    /// path: decodes then go through `memory`. Leave it off for keys whose bytes can change, like a
    /// workspace file path.
    public var cacheable = false
    /// The attempted side also records failures, so layout never retries a failed request forever.
    private var attemptedSide = 0
    private(set) var loadedSide = 0
    private var generation = 0

    static var memory: NSCache<NSString, ImageDecodeCache.Cached> { ImageDecodeCache.memory }
    public static func clearMemory() { ImageDecodeCache.clear() }
    private var memoryKey: String? { key.map { "\($0)|\(cover ? "cover" : "fit")" } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        fallback.alignment = .center
        fallback.lineHeight = 14
        addSubview(fallback)
    }

    deinit { task?.cancel() }

    public func set(key: String?, fallbackText: String, loader: Loader?, preview: CGImage? = nil, loadingText: String? = nil) {
        failureText = fallbackText
        pendingText = loadingText ?? fallbackText
        fallback.text = failed ? failureText : pendingText
        guard key != self.key else { return }
        self.key = key
        self.loader = loader
        reset()
        if let preview { show(preview) }
        start()
    }

    private func reset() {
        generation += 1
        task?.cancel(); task = nil
        attemptedSide = 0; loadedSide = 0; failed = false
        fallback.text = pendingText
        show(nil)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let key, image != nil { ImageTiming.mark("drop", key) }
            reset()
        } else { start() }
    }

    public override func viewDidHide() { super.viewDidHide(); reset() }
    public override func viewDidUnhide() { super.viewDidUnhide(); start() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); start() }

    /// A view placed before its frame waits instead of retaining a tiny first decode.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        start()
    }

    var decodeSide: Int? {
        if let requestedSide { return min(4096, max(1, requestedSide)) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return min(4096, Int((max(bounds.width, bounds.height, 16) * (window?.backingScaleFactor ?? 2)).rounded(.up)))
    }

    private func show(_ image: CGImage?) {
        self.image = image
        layer?.contents = image
        fallback.isHidden = image != nil
    }

    private func start() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let loader, let key, let side = decodeSide,
              task == nil, side > max(attemptedSide, loadedSide) else { return }
        let memoryKey = cacheable ? memoryKey : nil
        if let memoryKey, let hit = Self.memory.object(forKey: memoryKey as NSString), hit.side > loadedSide {
            loadedSide = hit.side
            show(hit.image)
            ImageTiming.mark("memory", "\(key) \(hit.side)/\(side)")
            onLoad?()
            if hit.side >= side { return }
        }
        attemptedSide = side
        failed = false
        fallback.text = pendingText
        let generation = self.generation
        ImageTiming.mark("request", "\(key) \(side)")
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result: ImageDecodeCache.Cached?
            if let memoryKey {
                result = await ImageDecodeCache.load(key: memoryKey, side: side, loader: loader)
            } else {
                result = await loader(side).map { ImageDecodeCache.Cached($0, side: side) }
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.task = nil
            ImageTiming.mark("pixels", "\(key) \(side)")
            // A failed upgrade keeps the smaller picture already on screen.
            if let result {
                self.loadedSide = result.side
                self.show(result.image)
            } else if self.image == nil {
                self.failed = true
                self.fallback.text = self.failureText
            }
            self.onLoad?()
            // Layout or backing scale may have changed during the decode. Upgrade once to its latest size.
            self.start()
        }
    }

    /// Offscreen snapshots have no window: decode every image under `root` now, at `scale`.
    static func loadAll(in root: NSView, scale: CGFloat = 2) async {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack += view.subviews
            guard let image = view as? AsyncImageView, let loader = image.loader else { continue }
            let side = image.requestedSide ?? Int((max(image.bounds.width, image.bounds.height, 16) * scale).rounded(.up))
            image.reset()
            image.loadedSide = side
            image.attemptedSide = side
            image.show(await loader(side))
            if image.image == nil { image.failed = true; image.fallback.text = image.failureText }
            image.onLoad?()
        }
    }

    public override func layout() {
        super.layout()
        fallback.frame = NSRect(x: 4, y: (bounds.height - 14) / 2, width: max(0, bounds.width - 8), height: 14)
    }
}

/// The draft's images above the editor (ChatComposer.tsx:7062-7230): `mb-3 flex flex-wrap gap-2`,
/// each tile `h-16 w-16 rounded-lg border border-border/80 bg-background` with the image
/// `object-cover`, upload progress in a `bg-background/85 text-3xs` strip at the bottom, a retry
/// overlay button after a failed upload and a `media-close` remove button at the top right.
public final class ComposerImageShelfView: DSView {
    public struct Tile: Equatable, Sendable {
        public var id: String
        public var name: String
        public var status: ComposerFileRow.Status
        public var fileURL: URL
        public var source: JSONValue?
        public init(id: String, name: String, status: ComposerFileRow.Status, fileURL: URL, source: JSONValue? = nil) {
            self.id = id; self.name = name; self.status = status; self.fileURL = fileURL; self.source = source
        }
    }

    func previewItem(_ item: ExpandedImagePreviewView.Item, for id: String) -> ExpandedImagePreviewView.Item {
        guard let view = views.first(where: { $0.id == id }) else { return item }
        return item.withPreview(from: view.image)
    }

    static let side: CGFloat = 64, gap: CGFloat = 8, marginBottom: CGFloat = 12

    public var tiles: [Tile] = [] { didSet { if tiles != oldValue { rebuild() } } }
    public var onRemove: ((String) -> Void)?
    public var onRetry: ((String) -> Void)?
    public var onExpand: ((String) -> Void)?
    private var views: [TileView] = []

    /// Rows that fit `width`, with the 12pt margin; 0 without images.
    public func preferredHeight(width: CGFloat) -> CGFloat {
        guard !tiles.isEmpty else { return 0 }
        return tileFrames(width: width).map(\.maxY).max().map { $0 + Self.marginBottom } ?? 0
    }
    private func tileFrames(width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        return tiles.map { tile in
            let size = tile.source == nil ? CGSize(width: 64, height: 64) : CGSize(width: min(208, width), height: 112)
            if x > 0 && x + size.width > width { x = 0; y += height + Self.gap; height = 0 }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + Self.gap; height = max(height, size.height)
            return frame
        }
    }

    private func rebuild() {
        while views.count > tiles.count { views.removeLast().removeFromSuperview() }
        while views.count < tiles.count {
            let v = TileView()
            v.owner = self
            addSubview(v)
            views.append(v)
        }
        for (view, tile) in zip(views, tiles) { view.configure(tile) }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for (view, frame) in zip(views, tileFrames(width: bounds.width)) { view.frame = frame }
    }

    fileprivate final class TileView: DSView, FocusWithinObserver {
        weak var owner: ComposerImageShelfView?
        /// Snap-shot frames reveal their remove button on hover or focus (ChatComposer.tsx:7198-7203):
        /// `opacity-0 transition-opacity group-hover/attachment:opacity-100 group-focus-within/attachment:opacity-100`.
        private var hover: HoverGroup?
        private var focusWithin = false
        private var isSnapShot = false
        func focusWithinChanged(_ focused: Bool) { focusWithin = focused; revealRemove() }
        private func revealRemove() { HoverReveal.fade([remove], visible: !isSnapShot || hover?.hovered == true || focusWithin) }
        private(set) var id = ""
        let image = AsyncImageView()
        private var details: SnapShotAttachmentDetailsView?
        private let progressStrip = DSView()
        private let progress = LabelView("", font: DSFont.ui(10), color: Themed.color(\.foreground))
        let remove = ButtonView(nil, icon: .x, variant: .mediaClose, size: .iconXs)
        let retry = ButtonView(nil, icon: .refreshCw, variant: .overlay, size: .iconXs)
        private lazy var retryTip = TooltipController.attach(to: retry, text: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            image.cacheable = true
            addSubview(image)
            progress.alignment = .center
            progress.lineHeight = 14
            progressStrip.addSubview(progress)
            addSubview(progressStrip)
            addSubview(retry)
            addSubview(remove)
            remove.action = { [weak self] in guard let self else { return }; owner?.onRemove?(id) }
            retry.action = { [weak self] in guard let self else { return }; owner?.onRetry?(id) }
            hover = HoverGroup(self) { [weak self] _ in self?.revealRemove() }
        }

        func configure(_ tile: Tile) {
            id = tile.id
            if details?.source != tile.source {
                details?.removeFromSuperview(); details = nil
                if let source = tile.source {
                    let view = SnapShotAttachmentDetailsView(source: source)
                    addSubview(view, positioned: .below, relativeTo: remove); details = view
                }
            }
            let url = tile.fileURL
            image.set(key: url.path, fallbackText: tile.name) { side in await ComposerImageIO.thumbnail(url, side: side, cover: true, measurementKey: url.path) }
            image.onContextMenu = { event, view in
                MediaAttachmentContextMenu.show(name: tile.name, load: { side in await ComposerImageIO.thumbnail(url, side: side, cover: false) }, event: event, view: view)
            }
            if isSnapShot != (tile.source != nil) {
                isSnapShot = tile.source != nil
                HoverReveal.withoutAnimation { revealRemove() }
            }
            remove.setAccessibilityLabel("Remove \(tile.name)")
            retry.setAccessibilityLabel("Retry upload for \(tile.name)")
            setAccessibilityLabel("Preview \(tile.name)")
            switch tile.status {
            case .uploading(let p):
                progressStrip.isHidden = false
                progress.text = ComposerFileRow.formatProgress(p)
                retry.isHidden = true
            case .failed(let reason):
                progressStrip.isHidden = true
                retry.isHidden = false
                retryTip.text = reason
            case .ready:
                progressStrip.isHidden = true
                retry.isHidden = true
            }
            needsLayout = true
        }

        override func updateLayer() {
            layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
            layer?.borderColor = Themed.color(\.border, 0.8).cgColor(in: self)
            progressStrip.layer?.backgroundColor = Themed.color(\.background, 0.85).cgColor(in: self)
        }

        override func layout() {
            super.layout()
            // Everything sits in the padding box, inside the 1px border.
            let inner = bounds.insetBy(dx: 1, dy: 1)
            image.frame = inner
            details?.frame = NSRect(x: inner.minX, y: inner.maxY - 66, width: inner.width, height: 66)
            progressStrip.frame = NSRect(x: inner.minX, y: inner.maxY - 14, width: inner.width, height: 14)
            progress.frame = NSRect(x: 4, y: 0, width: inner.width - 8, height: 14)
            // `absolute right-1 top-1` and `bottom-1 left-1`, inside the 1px border.
            remove.frame = NSRect(x: inner.maxX - 4 - 24, y: inner.minY + 4, width: 24, height: 24)
            retry.frame = NSRect(x: inner.minX + 4, y: inner.maxY - 4 - 24, width: 24, height: 24)
        }

        // `cursor-zoom-in`: a click on the image opens the preview.
        override func resetCursorRects() { addCursorRect(bounds, cursor: .zoomIn) }
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { owner?.onExpand?(id) }
        }
        override func mouseDown(with event: NSEvent) {}
    }
}

private extension NSCursor {
    /// macOS has no public zoom-in cursor; the pointing hand stands in.
    // ponytail: pointing hand instead of CSS `zoom-in`; draw a magnifier cursor if the difference shows
    static var zoomIn: NSCursor { .pointingHand }
}

/// The resting composer's images, after the prompt (ChatComposer.tsx:5236-5303): `flex gap-1 ps-1`, the first
/// three as `size-7 rounded-md border border-border/70 bg-muted/60` thumbnails that open the preview, then a
/// "+N" tile (`text-xs font-medium text-secondary-label`, `hover:bg-muted`) that expands the composer
/// (`getRestingComposerImagePreviewCounts`, composerFooterLayout.ts:5-14).
final class ComposerRestingImagesView: DSView {
    static let limit = 3, side: CGFloat = 28, gap: CGFloat = 4, leading: CGFloat = 4

    var onExpand: ((String) -> Void)?
    var onOverflow: (() -> Void)?
    private var thumbs: [Thumb] = []
    private let overflow = OverflowTile()
    private var ids: [String] = []

    func previewItem(_ item: ExpandedImagePreviewView.Item, for id: String) -> ExpandedImagePreviewView.Item {
        guard let index = ids.firstIndex(of: id), thumbs.indices.contains(index) else { return item }
        return item.withPreview(from: thumbs[index].image)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overflow.action = { [weak self] in self?.onOverflow?() }
        addSubview(overflow)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The block's width for `count` images; 0 without any.
    static func width(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let tiles = min(count, limit) + (count > limit ? 1 : 0)
        return leading + CGFloat(tiles) * side + CGFloat(tiles - 1) * gap
    }

    func set(_ tiles: [ComposerImageShelfView.Tile]) {
        let shown = Array(tiles.prefix(Self.limit))
        while thumbs.count > shown.count { thumbs.removeLast().removeFromSuperview() }
        while thumbs.count < shown.count { let t = Thumb(); addSubview(t); thumbs.append(t) }
        ids = shown.map(\.id)
        for (i, (view, tile)) in zip(thumbs, shown).enumerated() {
            let url = tile.fileURL
            view.image.set(key: url.path, fallbackText: "") { side in await ComposerImageIO.thumbnail(url, side: side, cover: true, measurementKey: url.path) }
            view.setAccessibilityLabel("Preview \(tile.name)")
            view.action = { [weak self] in guard let self, i < self.ids.count else { return }; self.onExpand?(self.ids[i]) }
        }
        let extra = tiles.count - shown.count
        overflow.isHidden = extra <= 0
        overflow.label.text = "+\(extra)"
        overflow.setAccessibilityLabel("Show \(extra) more image attachments")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = Self.leading
        let y = (bounds.height - Self.side) / 2
        for t in thumbs { t.frame = NSRect(x: x, y: y, width: Self.side, height: Self.side); x += Self.side + Self.gap }
        overflow.frame = NSRect(x: x, y: y, width: Self.side, height: Self.side)
    }

    private final class Thumb: ControlView {
        let image = AsyncImageView()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            layer?.cornerRadius = 6
            layer?.masksToBounds = true
            layer?.borderWidth = 1
            addSubview(image)
        }
        @MainActor required init?(coder: NSCoder) { fatalError() }
        override func updateLayer() {
            layer?.backgroundColor = Themed.color(\.muted, 0.6).cgColor(in: self)
            layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        }
        override func layout() { super.layout(); image.frame = bounds.insetBy(dx: 1, dy: 1) }
        // ponytail: pointing hand instead of CSS `zoom-in`, as the expanded shelf does
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private final class OverflowTile: ControlView {
        let label = LabelView("", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.secondaryLabel))
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            scalesWhenPressed = false
            transitions = .colors
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            label.alignment = .center
            label.lineHeight = 16
            addSubview(label)
        }
        @MainActor required init?(coder: NSCoder) { fatalError() }
        override func updateLayer() {
            Motion.setBackground(layer, Themed.color(\.muted, state.hovered ? 1 : 0.6).cgColor(in: self))
            layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self)
        }
        override func layout() { super.layout(); label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
