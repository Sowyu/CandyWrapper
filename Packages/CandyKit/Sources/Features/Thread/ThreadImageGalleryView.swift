import AppKit
import CryptoKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's image gallery card, under the tab band's pill: a masonry of what the agents looked at, newest first, and
/// one picture large after a click, fitted to the card. Only the tiles near the visible rect exist, and each decodes off
/// the main thread at its size through the timeline's loader (`MarkdownImages`). Tiles and large views share the decode
/// cache (`ImageDecodeCache`), so a reopened gallery shows its pictures in the first frame.
// ponytail: tiles share the 48 MB decode NSCache with the timeline; give the gallery its own LRU if it evicts timeline images
public final class ThreadImageGalleryView: DSView {
    /// The card's width and its default tallest; `maxHeight` replaces the height with the room the window has.
    static let size = NSSize(width: 540, height: 470)
    /// The empty state's height.
    static let minHeight: CGFloat = 160
    static let inset: CGFloat = 10, gap: CGFloat = 8, header: CGFloat = 36, footer: CGFloat = 36
    /// The large picture's body never gets shorter than this, so its footer and arrows keep their room.
    static let minBody: CGFloat = 120
    /// The card never runs the window's height (the user, r5: "make it just the right size"): at most 420pt and
    /// 55% of the window, and never past the room below the pill.
    static func cap(room: CGFloat, windowHeight: CGFloat) -> CGFloat {
        min(room, 420, (windowHeight * 0.55).rounded(.down))
    }

    /// Newest first. Setting it keeps the picture shown large, by its identity.
    public var images: [GalleryImage] = [] {
        didSet {
            guard images != oldValue else { return }
            if let shown = large.flatMap({ oldValue.indices.contains($0) ? oldValue[$0] : nil }) {
                large = images.firstIndex { $0.key == shown.key || $0.dedupeKey == shown.dedupeKey }
            }
            reload()
        }
    }
    /// The tallest the card may grow, from the window's room below the pill. Defaults to `size.height`.
    public var maxHeight: CGFloat = ThreadImageGalleryView.size.height { didSet { if maxHeight != oldValue { reload() } } }
    /// Every source of a tile failed.
    public var onFailed: ((GalleryImage) -> Void)?
    /// A tile's downloaded bytes hashed to this.
    public var onHash: ((GalleryImage, String) -> Void)?
    /// The card's height changed; the popup moves to fit.
    public var onResize: (() -> Void)?
    public var onOpenInThread: ((GalleryImage) -> Void)?
    public var onReveal: ((GalleryImage) -> Void)?
    /// "Open gallery": the full gallery, on the picture shown large if there is one.
    public var onOpenGallery: ((GalleryImage?) -> Void)?
    /// Whether "Reveal in Finder" applies: a host file on this Mac.
    public var canReveal: ((GalleryImage) -> Bool)?

    let title = LabelView("Agent images", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let back = ButtonView(nil, icon: .arrowLeft, variant: .ghost, size: .iconXs)
    let expand = ButtonView(nil, icon: .maximize2, variant: .ghost, size: .iconXs)
    private let previous = ButtonView(nil, icon: .chevronLeft, variant: .ghost, size: .iconXs)
    private let next = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconXs)
    let grid = GalleryMasonryView(metrics: .init(inset: NSEdgeInsets(top: 4, left: ThreadImageGalleryView.inset, bottom: ThreadImageGalleryView.inset,
                                                                   right: ThreadImageGalleryView.inset),
                                                 gap: ThreadImageGalleryView.gap, minColumn: 150, radius: RedesignTokens.Radius.control))
    private lazy var scroll = ScrollAreaView(documentView: grid, scrollFade: true)
    private let empty = TextBlockView("No images yet", font: DSFont.ui(12), lineHeight: 17, color: Themed.color(\.mutedForeground))
    let picture = AsyncImageView()
    /// The large picture's zoom, inside the picture's own frame: the card keeps its size.
    private(set) lazy var zoom = ZoomableImageView(picture: picture)
    private let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let openInThread = ButtonView("Open in thread", icon: .arrowUpRight, variant: .ghost, size: .xs)
    private let reveal = ButtonView("Reveal in Finder", icon: .folderOpen, variant: .ghost, size: .xs)
    /// The grid's last row while it holds more than the card shows: the full gallery.
    let showAll = ButtonView("Show all in gallery", variant: .ghost, size: .xs)

    /// The picture shown large, or nil for the grid.
    var large: Int? { didSet { if large != oldValue { reload() } } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        empty.alignment = .center
        count.alignment = .right
        picture.cover = false
        picture.cacheable = true
        picture.fallback.text = "Loading…"
        picture.layer?.cornerRadius = RedesignTokens.Radius.control
        picture.layer?.cornerCurve = .continuous
        picture.onLoad = { [weak self] in self?.pictureMeasured() }
        zoom.layer?.cornerRadius = RedesignTokens.Radius.control
        zoom.layer?.cornerCurve = .continuous
        detail.truncation = .middle
        for view in [title, count, back, expand, previous, next, scroll, empty, zoom, detail, openInThread, reveal, showAll] as [NSView] { addSubview(view) }
        scroll.scrollsHorizontally = false
        grid.widthHint = Self.size.width
        grid.makeLoader = { [weak self] image in
            Self.loader(image, onHash: { hash in self?.onHash?(image, hash) }) { self?.onFailed?(image) }
        }
        grid.onContentHeight = { [weak self] in self?.resizeToFit() }
        back.setTooltip("Back to all images")
        back.setAccessibilityLabel("Back to all images")
        expand.setTooltip("Open gallery")
        expand.setAccessibilityLabel("Open gallery")
        previous.setTooltip("Previous image")
        previous.setAccessibilityLabel("Previous image")
        next.setTooltip("Next image")
        next.setAccessibilityLabel("Next image")
        back.action = { [weak self] in self?.large = nil }
        expand.action = { [weak self] in self?.onOpenGallery?(self?.shown) }
        showAll.action = { [weak self] in self?.onOpenGallery?(nil) }
        previous.action = { [weak self] in self?.step(-1) }
        next.action = { [weak self] in self?.step(1) }
        openInThread.action = { [weak self] in self?.shown.map { self?.onOpenInThread?($0) } }
        reveal.action = { [weak self] in self?.shown.map { self?.onReveal?($0) } }
        grid.onSelect = { [weak self] index in self?.large = index }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent images")
        reload()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.size.width, height: wantedHeight) }
    public override var fittingSize: NSSize { intrinsicContentSize }

    /// The tallest the card gets here: the window's room, at least the empty state.
    private var cap: CGFloat { max(Self.minHeight, maxHeight) }

    /// The area a large picture may fill: the card's width inside its inset, and its tallest body.
    var pictureArea: CGSize {
        CGSize(width: Self.size.width - 2 * Self.inset, height: max(Self.minBody, cap - Self.header - Self.footer))
    }

    /// The large picture's size by the fit rule (`GalleryLayout.fit`); the whole area while its size isn't known.
    var pictureSize: CGSize {
        let area = pictureArea
        guard let natural = shown?.naturalSize else { return area }
        return GalleryLayout.fit(natural, in: area, scale: window?.backingScaleFactor ?? 2)
    }

    /// The grid: as tall as its masonry, with 4:3 for pictures not measured yet. A large picture: its header, its
    /// fitted height and its footer. Both between `minHeight` and the window's room.
    var wantedHeight: CGFloat {
        if shown != nil { return min(cap, Self.header + max(Self.minBody, pictureSize.height) + Self.footer) }
        guard !images.isEmpty else { return Self.minHeight }
        return min(cap, max(Self.minHeight, Self.header + grid.estimatedHeight))
    }

    /// The grid holds more than the card shows, so its last row offers the full gallery.
    var overflows: Bool { shown == nil && !images.isEmpty && Self.header + grid.estimatedHeight > cap }

    private var shown: GalleryImage? { large.flatMap { images.indices.contains($0) ? images[$0] : nil } }

    /// ← and → step through the large view; Escape goes back to the grid, then closes.
    public func handleKey(_ key: PopupKey) -> Bool {
        switch key {
        case .left where large != nil: step(-1); return true
        case .right where large != nil: step(1); return true
        case .escape where large != nil: large = nil; return true
        default: return false
        }
    }

    /// A pinch over the grid stays in the card rather than reaching the page under it.
    public override func magnify(with event: NSEvent) {}

    private func step(_ delta: Int) {
        guard let large, !images.isEmpty else { return }
        self.large = (large + delta + images.count) % images.count
    }

    /// The picture's pixels arrived, and with them its natural size if the signed URL didn't carry one.
    private func pictureMeasured() {
        if let image = shown, image.naturalSize == nil, let cg = picture.image {
            MarkdownImages.record(CGSize(width: cg.width, height: cg.height), for: image.key)
        }
        resizeToFit()
        needsLayout = true
    }

    private func resizeToFit() {
        let height = wantedHeight
        if showAll.isHidden == overflows { showAll.isHidden = !overflows; needsLayout = true }
        guard frame.height != height else { return }
        setFrameSize(NSSize(width: Self.size.width, height: height))
        invalidateIntrinsicContentSize()
        onResize?()
    }

    private func reload() {
        let image = shown
        if large != nil, image == nil { large = nil; return }
        count.text = image == nil ? "\(images.count)" : "\(large! + 1) of \(images.count)"
        let gridShown = image == nil
        scroll.isHidden = !gridShown || images.isEmpty
        empty.isHidden = !gridShown || !images.isEmpty
        title.isHidden = !gridShown
        expand.isHidden = images.isEmpty
        for view in [back, previous, next, zoom, detail, openInThread] as [NSView] { view.isHidden = gridShown }
        if picture.key != image?.pixelKey { zoom.reset() }
        previous.isHidden = gridShown || images.count < 2
        next.isHidden = previous.isHidden
        reveal.isHidden = image.map { !(canReveal?($0) ?? false) } ?? true
        if gridShown { picture.set(key: nil, fallbackText: "", loader: nil) }
        if let image {
            picture.set(key: image.pixelKey, fallbackText: "Image unavailable",
                        loader: Self.loader(image, onHash: { [weak self] hash in self?.onHash?(image, hash) }) { [weak self] in self?.onFailed?(image) },
                        preview: ImageDecodeCache.preview(for: image.pixelKey), loadingText: "Loading…")
            detail.text = Self.caption(image, long: true) + " · " + Self.name(image)
            picture.setAccessibilityLabel(Self.name(image) + ", " + Self.caption(image))
        } else {
            grid.images = images
        }
        showAll.title = "Show all \(images.count) in gallery"
        resizeToFit()
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let i = Self.inset, w = bounds.width
        let headerMid = (Self.header / 2).rounded()
        back.frame = NSRect(x: i - 2, y: headerMid - 12, width: 24, height: 24)
        title.frame = NSRect(x: i + 4, y: headerMid - 9, width: 160, height: 18)
        // The grid's count sits on the card's right padding, the large view's after the back arrow.
        let countWidth = ceil(count.intrinsicContentSize.width)
        if large == nil {
            count.alignment = .right
            count.frame = NSRect(x: w - i - 4 - countWidth, y: headerMid - 9, width: countWidth, height: 18)
            expand.frame = NSRect(x: count.frame.minX - 8 - 24, y: headerMid - 12, width: 24, height: 24)
        } else {
            count.alignment = .left
            count.frame = NSRect(x: back.frame.maxX + 6, y: headerMid - 9, width: 140, height: 18)
        }
        next.frame = NSRect(x: w - i - 22, y: headerMid - 12, width: 24, height: 24)
        previous.frame = NSRect(x: next.frame.minX - 26, y: headerMid - 12, width: 24, height: 24)
        if large != nil { expand.frame = NSRect(x: (previous.isHidden ? next.frame.maxX - 24 : previous.frame.minX - 30), y: headerMid - 12, width: 24, height: 24) }
        let body = NSRect(x: 0, y: Self.header, width: w, height: bounds.height - Self.header)
        scroll.frame = showAll.isHidden ? body : NSRect(x: 0, y: body.minY, width: w, height: max(0, body.height - Self.footer))
        let showAllWidth = min(w - 2 * i, showAll.intrinsicContentSize.width)
        showAll.frame = NSRect(x: ((w - showAllWidth) / 2).rounded(), y: bounds.height - Self.footer + (Self.footer - 24) / 2,
                               width: showAllWidth, height: 24)
        scroll.layoutSubtreeIfNeeded()
        grid.fitWidth()
        let emptyWidth = w - 8 * i, emptyHeight = empty.height(forWidth: emptyWidth)
        empty.frame = NSRect(x: 4 * i, y: (body.midY - emptyHeight / 2).rounded(), width: emptyWidth, height: emptyHeight)
        // Large view: the picture at its fitted size, centred between the header and the footer.
        let footer = Self.footer
        let room = NSRect(x: i, y: body.minY, width: w - 2 * i, height: max(1, body.height - footer))
        let size = pictureSize
        let fitted = NSSize(width: min(size.width, room.width), height: min(size.height, room.height))
        zoom.frame = NSRect(x: (room.midX - fitted.width / 2).rounded(), y: (room.midY - fitted.height / 2).rounded(), width: fitted.width, height: fitted.height)
        let buttonsY = bounds.height - footer + (footer - 24) / 2
        var x = w - i
        for button in [reveal, openInThread] where !button.isHidden {
            let bw = button.intrinsicContentSize.width
            x -= bw
            button.frame = NSRect(x: x, y: buttonsY, width: bw, height: 24)
            x -= 4
        }
        detail.frame = NSRect(x: i + 4, y: buttonsY + 3, width: max(0, x - i - 8), height: 18)
    }

    /// A tile's caption ends in "2×" for a picture viewed twice; the large view, with room, says "viewed 2×".
    static func caption(_ image: GalleryImage, long: Bool = false) -> String {
        let when = TimestampFormat.formatRelativeTimeLabel(image.at.raw, nowMs: TimestampFormat.nowMs())
        let views = image.views > 1 ? (long ? " · viewed \(image.views)×" : " · \(image.views)×") : ""
        return (when.isEmpty ? image.agent : image.agent + " · " + when) + views
    }

    static func name(_ image: GalleryImage) -> String {
        switch image.source {
        case .file(let path): (path as NSString).lastPathComponent
        case .url(let url): url.lowercased().hasPrefix("data:") ? "Inline image" : (URL(string: url)?.lastPathComponent ?? url)
        case .toolOutput(let output): "Tool output \(output.index + 1)"
        }
    }

    /// Tries the image's sources in order (`GalleryImage.attempts`): our kept copy, the server's stored copy, then the
    /// file or URL itself. Host files and tool outputs sign through `assets.createUrl` on their own thread
    /// (`useAssetUrlState`, apps/web/src/assets/assetUrls.ts:20-41), with the timeline's loaders.
    /// `onHash` gets the SHA-256 of bytes it downloads, once, so identical pictures merge into one tile.
    static func loader(_ image: GalleryImage, onHash: @escaping @MainActor (String) -> Void = { _ in },
                       onFailed: @escaping @MainActor () -> Void = {}) -> AsyncImageView.Loader {
        nonisolated(unsafe) let hashed = onHash
        let onFile: @Sendable (URL) async -> Void = { url in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            await hashed(hash)
        }
        let loaders: [AsyncImageView.Loader] = image.attempts.map { attempt in
            switch attempt {
            case .stored(let stored): MarkdownImages.assetLoader(key: stored.key, resource: stored.resource, onFile: onFile)
            case .kept(let thread, let item): MarkdownImages.keptLoader(thread: thread, item: item, sizeKey: image.key)
            case .source:
                if let resource = image.resource { MarkdownImages.assetLoader(key: image.key, resource: resource, onFile: onFile) }
                else if case .url(let url) = image.source { MarkdownImages.loader(.direct(url)) }
                else { { _ in nil } }
            }
        }
        nonisolated(unsafe) let failed = onFailed
        return { side in
            for load in loaders {
                if let image = await load(side) { return image }
                if Task.isCancelled { return nil }
            }
            await failed()
            return nil
        }
    }
}
