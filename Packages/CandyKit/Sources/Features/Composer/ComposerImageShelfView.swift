import AppKit
import DesignSystem

/// An image drawn from a loader that decodes off the main thread at display size (`object-cover`
/// by default). Nothing is decoded until the view sits in a window.
public final class AsyncImageView: DSView {
    /// Decodes for a pixel side; called once per `key`.
    public typealias Loader = @Sendable (_ side: Int) async -> CGImage?
    public private(set) var key: String?
    private var loader: Loader?
    private var task: Task<Void, Never>?
    public var cover = true { didSet { layer?.contentsGravity = cover ? .resizeAspectFill : .resizeAspect } }
    /// Shown until the image arrives or when it fails (`fallback`).
    public let fallback = LabelView("", font: DSFont.ui(10), color: Themed.color(\.secondaryLabel))
    public private(set) var image: CGImage?
    public var onLoad: (() -> Void)?
    /// The pixel side to decode at; by default the view's own size at the screen's scale.
    public var requestedSide: Int?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        fallback.alignment = .center
        fallback.lineHeight = 14
        addSubview(fallback)
    }

    public func set(key: String?, fallbackText: String, loader: Loader?) {
        fallback.text = fallbackText
        guard key != self.key else { return }
        self.key = key
        self.loader = loader
        task?.cancel()
        task = nil
        image = nil
        layer?.contents = nil
        fallback.isHidden = false
        start()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        start()
    }

    private func start() {
        guard window != nil, task == nil, image == nil, let loader, let key else { return }
        let scale = window?.backingScaleFactor ?? 2
        let side = requestedSide ?? Int((max(bounds.width, bounds.height, 16) * scale).rounded(.up))
        task = Task { [weak self] in
            let image = await loader(side)
            guard let self, !Task.isCancelled, self.key == key else { return }
            self.image = image
            self.layer?.contents = image
            self.fallback.isHidden = image != nil
            self.onLoad?()
        }
    }

    /// Offscreen snapshots have no window: decode every image under `root` now, at `scale`.
    static func loadAll(in root: NSView, scale: CGFloat = 2) async {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack += view.subviews
            guard let image = view as? AsyncImageView, let loader = image.loader else { continue }
            let side = image.requestedSide ?? Int((max(image.bounds.width, image.bounds.height, 16) * scale).rounded(.up))
            image.task?.cancel()
            image.image = await loader(side)
            image.layer?.contents = image.image
            image.fallback.isHidden = image.image != nil
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
        public init(id: String, name: String, status: ComposerFileRow.Status, fileURL: URL) {
            self.id = id; self.name = name; self.status = status; self.fileURL = fileURL
        }
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
        let rows = CGFloat(rowCount(width))
        return rows * Self.side + (rows - 1) * Self.gap + Self.marginBottom
    }

    private func perRow(_ width: CGFloat) -> Int { max(1, Int((width + Self.gap) / (Self.side + Self.gap))) }
    private func rowCount(_ width: CGFloat) -> Int { (tiles.count + perRow(width) - 1) / perRow(width) }

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
        let n = perRow(bounds.width)
        for (i, view) in views.enumerated() {
            view.frame = NSRect(x: CGFloat(i % n) * (Self.side + Self.gap), y: CGFloat(i / n) * (Self.side + Self.gap),
                                width: Self.side, height: Self.side)
        }
    }

    fileprivate final class TileView: DSView {
        weak var owner: ComposerImageShelfView?
        private(set) var id = ""
        let image = AsyncImageView()
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
            addSubview(image)
            progress.alignment = .center
            progress.lineHeight = 14
            progressStrip.addSubview(progress)
            addSubview(progressStrip)
            addSubview(retry)
            addSubview(remove)
            remove.action = { [weak self] in guard let self else { return }; owner?.onRemove?(id) }
            retry.action = { [weak self] in guard let self else { return }; owner?.onRetry?(id) }
        }

        func configure(_ tile: Tile) {
            id = tile.id
            let url = tile.fileURL
            image.set(key: url.path, fallbackText: tile.name) { side in await ComposerImageIO.thumbnail(url, side: side, cover: true) }
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
