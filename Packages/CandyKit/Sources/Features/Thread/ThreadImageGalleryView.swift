import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's image gallery card, under the tab band's pill: a grid of what the agents looked at, newest first, and
/// one picture large after a click. Only the cells on screen exist, and each decodes its thumbnail off the main thread
/// at cell size through the timeline's loader (`MarkdownImages`). Thumbnails and large views share the decode cache
/// (`ImageDecodeCache`), so a reopened gallery shows its pictures in the first frame.
// ponytail: thumbnails share the 48 MB decode NSCache with the timeline; give the gallery its own LRU if it evicts timeline images
public final class ThreadImageGalleryView: DSView {
    static let size = NSSize(width: 540, height: 470)
    static let inset: CGFloat = 10, gap: CGFloat = 8, columns = 4, header: CGFloat = 36, caption: CGFloat = 18

    /// Newest first. Setting it keeps the picture shown large, by its identity.
    public var images: [GalleryImage] = [] {
        didSet {
            guard images != oldValue else { return }
            if let shown = large.flatMap({ oldValue.indices.contains($0) ? oldValue[$0].key : nil }) {
                large = images.firstIndex { $0.key == shown }
            }
            reload()
        }
    }
    public var onOpenInThread: ((GalleryImage) -> Void)?
    public var onReveal: ((GalleryImage) -> Void)?
    /// Whether "Reveal in Finder" applies: a host file on this Mac.
    public var canReveal: ((GalleryImage) -> Bool)?

    private let title = LabelView("Agent images", font: DSFont.ui(13, weight: .semibold), color: Themed.color(\.foreground))
    private let count = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let back = ButtonView(nil, icon: .arrowLeft, variant: .ghost, size: .iconXs)
    private let previous = ButtonView(nil, icon: .chevronLeft, variant: .ghost, size: .iconXs)
    private let next = ButtonView(nil, icon: .chevronRight, variant: .ghost, size: .iconXs)
    private let grid = GalleryGridView()
    private lazy var scroll = ScrollAreaView(documentView: grid, scrollFade: true)
    private let empty = LabelView("No images yet", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let picture = AsyncImageView()
    private let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let openInThread = ButtonView("Open in thread", icon: .arrowUpRight, variant: .ghost, size: .xs)
    private let reveal = ButtonView("Reveal in Finder", icon: .folderOpen, variant: .ghost, size: .xs)

    /// The picture shown large, or nil for the grid.
    private var large: Int? { didSet { if large != oldValue { reload() } } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        empty.alignment = .center
        picture.cover = false
        picture.cacheable = true
        picture.fallback.text = "Loading…"
        picture.layer?.cornerRadius = 8
        detail.truncation = .middle
        for view in [title, count, back, previous, next, scroll, empty, picture, detail, openInThread, reveal] as [NSView] { addSubview(view) }
        back.toolTip = "Back to all images"
        back.setAccessibilityLabel("Back to all images")
        previous.toolTip = "Previous image"
        next.toolTip = "Next image"
        back.action = { [weak self] in self?.large = nil }
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

    public override var intrinsicContentSize: NSSize { Self.size }
    public override var fittingSize: NSSize { Self.size }

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

    private func step(_ delta: Int) {
        guard let large, !images.isEmpty else { return }
        self.large = (large + delta + images.count) % images.count
    }

    private func reload() {
        let image = shown
        if large != nil, image == nil { large = nil; return }
        count.text = image == nil ? "\(images.count)" : "\(large! + 1) of \(images.count)"
        let gridShown = image == nil
        scroll.isHidden = !gridShown || images.isEmpty
        empty.isHidden = !gridShown || !images.isEmpty
        title.isHidden = !gridShown
        for view in [back, previous, next, picture, detail, openInThread] as [NSView] { view.isHidden = gridShown }
        previous.isHidden = gridShown || images.count < 2
        next.isHidden = previous.isHidden
        reveal.isHidden = image.map { !(canReveal?($0) ?? false) } ?? true
        if gridShown { picture.set(key: nil, fallbackText: "", loader: nil) }
        if let image {
            picture.set(key: image.pixelKey, fallbackText: "Image unavailable", loader: Self.loader(image),
                        preview: ImageDecodeCache.preview(for: image.pixelKey), loadingText: "Loading…")
            detail.text = Self.caption(image) + " · " + Self.name(image)
            picture.toolTip = image.filePath
        } else {
            grid.images = images
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let i = Self.inset, w = bounds.width
        let headerMid = (Self.header / 2).rounded()
        back.frame = NSRect(x: i - 2, y: headerMid - 12, width: 24, height: 24)
        title.frame = NSRect(x: i + 4, y: headerMid - 9, width: 120, height: 18)
        let countX = large == nil ? title.frame.maxX : back.frame.maxX + 6
        count.frame = NSRect(x: countX, y: headerMid - 9, width: 90, height: 18)
        next.frame = NSRect(x: w - i - 22, y: headerMid - 12, width: 24, height: 24)
        previous.frame = NSRect(x: next.frame.minX - 26, y: headerMid - 12, width: 24, height: 24)
        let body = NSRect(x: 0, y: Self.header, width: w, height: bounds.height - Self.header)
        scroll.frame = body
        empty.frame = NSRect(x: 0, y: body.midY - 9, width: w, height: 18)
        // Large view: the picture fits above a footer with its caption and actions.
        let footer: CGFloat = 36
        picture.frame = NSRect(x: i, y: body.minY, width: w - 2 * i, height: body.height - footer)
        picture.requestedSide = Int((max(picture.frame.width, picture.frame.height) * (window?.backingScaleFactor ?? 2)).rounded(.up))
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

    static func caption(_ image: GalleryImage) -> String {
        let when = TimestampFormat.formatRelativeTimeLabel(image.at.raw, nowMs: TimestampFormat.nowMs())
        return when.isEmpty ? image.agent : image.agent + " · " + when
    }

    static func name(_ image: GalleryImage) -> String {
        switch image.source {
        case .file(let path): (path as NSString).lastPathComponent
        case .url(let url): url.lowercased().hasPrefix("data:") ? "Inline image" : (URL(string: url)?.lastPathComponent ?? url)
        case .toolOutput(let output): "Tool output \(output.index + 1)"
        }
    }

    /// The timeline's loaders: host files and tool outputs sign through `assets.createUrl` on their own thread
    /// (`useAssetUrlState`, apps/web/src/assets/assetUrls.ts:20-41); URLs load directly.
    static func loader(_ image: GalleryImage) -> AsyncImageView.Loader {
        if let resource = image.resource { return MarkdownImages.assetLoader(key: image.key, resource: resource) }
        if case .url(let url) = image.source { return MarkdownImages.loader(.direct(url)) }
        return { _ in nil }
    }
}

/// The grid's document: it lays out every cell's frame but keeps views only for the rows on screen.
final class GalleryGridView: DSView {
    var images: [GalleryImage] = [] { didSet { if images != oldValue { cells.values.forEach { $0.removeFromSuperview() }; cells = [:]; resize() } } }
    var onSelect: ((Int) -> Void)?
    private var cells: [Int: GalleryCellView] = [:]
    private var observer: NSObjectProtocol?

    private var cellSize: NSSize {
        let g = ThreadImageGalleryView.self
        let w = ((bounds.width - 2 * g.inset - CGFloat(g.columns - 1) * g.gap) / CGFloat(g.columns)).rounded(.down)
        return NSSize(width: max(40, w), height: max(40, w * 0.75).rounded() + g.caption)
    }

    func frame(of index: Int) -> NSRect {
        let g = ThreadImageGalleryView.self, size = cellSize
        let row = index / g.columns, column = index % g.columns
        return NSRect(x: g.inset + CGFloat(column) * (size.width + g.gap), y: 4 + CGFloat(row) * (size.height + g.gap),
                      width: size.width, height: size.height)
    }

    private func resize() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let rows = (images.count + ThreadImageGalleryView.columns - 1) / ThreadImageGalleryView.columns
        let height = 4 + CGFloat(rows) * (cellSize.height + ThreadImageGalleryView.gap) + ThreadImageGalleryView.inset
        let size = NSSize(width: clip.bounds.width, height: max(clip.bounds.height, height))
        if frame.size != size { setFrameSize(size) }
        tile()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tile() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resize()
    }

    override func layout() {
        super.layout()
        resize()
    }

    /// Cells for the visible rows and one row either side; the rest go, with their pixels.
    func tile() {
        let visible = visibleRect.insetBy(dx: 0, dy: -cellSize.height)
        let wanted = Set(images.indices.filter { frame(of: $0).intersects(visible) })
        for (index, cell) in cells where !wanted.contains(index) { cell.removeFromSuperview(); cells[index] = nil }
        for index in wanted {
            let cell = cells[index] ?? {
                let cell = GalleryCellView()
                cell.action = { [weak self] in self?.onSelect?(index) }
                addSubview(cell)
                cells[index] = cell
                return cell
            }()
            cell.frame = frame(of: index)
            cell.show(images[index])
        }
    }
}

/// A thumbnail and its caption: which agent saw it and when.
final class GalleryCellView: ControlView {
    private let thumb = AsyncImageView()
    private let caption = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let ring = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        thumb.cacheable = true
        thumb.layer?.cornerRadius = 6
        caption.lineHeight = 14
        addSubview(thumb)
        addSubview(caption)
        ring.cornerRadius = 7
        ring.borderWidth = 1.5
        layer?.addSublayer(ring)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ image: GalleryImage) {
        thumb.set(key: image.pixelKey, fallbackText: "Unavailable", loader: ThreadImageGalleryView.loader(image), loadingText: "")
        caption.text = ThreadImageGalleryView.caption(image)
        toolTip = image.filePath ?? ThreadImageGalleryView.name(image)
        setAccessibilityLabel(ThreadImageGalleryView.name(image) + ", " + caption.text)
    }

    override func layout() {
        super.layout()
        let imageHeight = bounds.height - ThreadImageGalleryView.caption
        thumb.frame = NSRect(x: 0, y: 0, width: bounds.width, height: imageHeight)
        caption.frame = NSRect(x: 1, y: imageHeight + 3, width: bounds.width - 2, height: 14)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.frame = thumb.frame.insetBy(dx: -1, dy: -1)
        CATransaction.commit()
        restyle()
    }

    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.borderColor = state.hovered || state.focusVisible ? Themed.color(\.ring).cgColor(in: self) : nil
        thumb.layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
        caption.color = Themed.color(state.hovered ? \.foreground : \.mutedForeground)
        CATransaction.commit()
    }
}
