import AppKit
import DesignSystem
import T3Store

/// `ViewedImagesTimelineRow` (4928 chat/TimelineWorkEntryRow.tsx:250-282, #30473): the images a tool group opened,
/// below the group whether it is folded or open, `flex flex-wrap items-start gap-2 px-0.5` in `pb-2`. Each is a
/// `ChatMarkdownAssetImage` at most 10rem tall. Clicking one opens the viewer on all of them (#34333).
/// A file that fails to load leaves the row, as viewed files do in open work rows here.
final class ViewedImagesRowView: TimelineRowView {
    static let maxHeight: CGFloat = 160
    private static let gap: CGFloat = 8
    private static let inset: CGFloat = 2

    private var images: [WorkImage] = []
    private var imageViews: [String: AsyncImageView] = [:]
    private var tooltips: [String: TooltipController] = [:]
    private var contentVisible = true

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .viewedImages(let paths) = item.row.kind else { return }
        let root = context?.workspaceRoot
        images = paths.compactMap { path in
            guard case .workspaceFile(let file) = MarkdownImageSource.classify(path, workspaceRoot: root) else { return nil }
            return .file(file, workspaceRoot: root)
        }
        needsLayout = true
    }

    /// The images still shown: a failed file takes no space.
    private var shown: [WorkImage] { images.filter { !MarkdownImages.failed.contains($0.key) } }

    /// `ChatMarkdownImage`: a 16:9 slot until the size is known, then the image's box with its 1px frame.
    private static func box(_ image: WorkImage, width: CGFloat) -> (size: CGSize, settled: Bool) {
        if let natural = MarkdownImages.sizes[image.key] {
            return (MarkdownImages.displaySize(natural: natural, maxWidth: width, border: 1, maxHeight: maxHeight), true)
        }
        let w = min(width, MarkdownStyle.imageMaxWidth)
        return (CGSize(width: w, height: min(w * 9 / 16, maxHeight)), false)
    }

    /// Wraps the boxes into lines like `flex-wrap items-start`.
    private func frames(width: CGFloat) -> [(image: WorkImage, frame: CGRect, settled: Bool)] {
        let inner = max(1, width - 2 * Self.inset)
        var out: [(WorkImage, CGRect, Bool)] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for image in shown {
            let (size, settled) = Self.box(image, width: inner)
            if x > 0, x + size.width > inner { x = 0; y += lineHeight + Self.gap; lineHeight = 0 }
            out.append((image, CGRect(x: Self.inset + x, y: y, width: size.width, height: size.height), settled))
            x += size.width + Self.gap
            lineHeight = max(lineHeight, size.height)
        }
        return out
    }

    override func height(forWidth width: CGFloat) -> CGFloat {
        let laid = frames(width: width)
        guard let bottom = laid.map(\.frame.maxY).max() else { return 0 }
        return bottom + 8
    }

    override func layout() {
        super.layout()
        guard contentVisible, !isHiddenOrHasHiddenAncestor else { release(); return }
        var kept = Set<String>()
        for (image, frame, settled) in frames(width: bounds.width) {
            kept.insert(image.key)
            let view = imageViews[image.key] ?? make(image)
            imageViews[image.key] = view
            view.frame = settled ? frame.insetBy(dx: 1, dy: 1) : frame
            view.layer?.cornerRadius = settled ? 9 : 10
            view.requestedSide = Int((max(min(bounds.width, MarkdownStyle.imageMaxWidth), Self.maxHeight) * (window?.backingScaleFactor ?? 2)).rounded(.up))
            view.set(key: image.key, fallbackText: "", loader: image.loader)
            view.setAccessibilityLabel("Preview " + image.alt)
            tooltips[image.key]?.text = image.reference?.tooltip ?? ""
        }
        for (key, view) in imageViews where !kept.contains(key) {
            view.removeFromSuperview(); imageViews[key] = nil; tooltips[key] = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    private func make(_ image: WorkImage) -> AsyncImageView {
        let view = AsyncImageView()
        view.cover = false
        view.cacheable = image.cacheable
        view.fallback.color = Themed.color(\.mutedForeground)
        view.fallback.font = DSFont.ui(12)
        view.setAccessibilityRole(.button)
        if image.reference != nil { tooltips[image.key] = TooltipController.attach(to: view, text: "", variant: .code) }
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expand(_:))))
        view.onLoad = { [weak self, weak view] in
            guard let self, let view, let key = view.key, self.imageViews[key] === view else { return }
            guard view.image == nil else { self.window?.invalidateCursorRects(for: self); return }
            MarkdownImages.failed.insert(key)
            NotificationCenter.default.post(name: MarkdownImages.didMeasure, object: nil, userInfo: ["key": key])
            self.needsLayout = true
        }
        view.onContextMenu = { [weak self, weak view] event, source in
            guard let self, let key = view?.key, let image = self.images.first(where: { $0.key == key }) else { return }
            var openFile: (() -> Void)?
            if case .file(_, let relative?)? = image.reference, let open = MarkdownImages.openInFileViewer { openFile = { open(relative) } }
            MediaAttachmentContextMenu.show(name: image.alt, load: image.loader, event: event, view: source, reference: image.reference, openFile: openFile)
        }
        addSubview(view)
        return view
    }

    @objc private func expand(_ gesture: NSClickGestureRecognizer) {
        guard let window, let view = gesture.view as? AsyncImageView, view.image != nil, let key = view.key else { return }
        let gallery = shown
        guard let index = gallery.firstIndex(where: { $0.key == key }) else { return }
        let items = gallery.map { image -> ExpandedImagePreviewView.Item in
            let item = ExpandedImagePreviewView.Item(key: image.key, name: image.alt, cacheable: image.cacheable, load: image.loader, reference: image.reference)
            return image.key == key ? item.withPreview(from: view, sharingLoader: true) : item
        }
        ExpandedImagePreviewView(items: items, index: index).present(in: window)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        var cursor = NSCursor.pointingHand
        if #available(macOS 15, *) { cursor = .zoomIn }
        for view in imageViews.values where view.image != nil { addCursorRect(view.frame, cursor: cursor) }
    }

    override func setContentVisible(_ visible: Bool) {
        super.setContentVisible(visible)
        guard visible != contentVisible else { return }
        contentVisible = visible
        if visible { needsLayout = true } else { release() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        release()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        release()
        images = []
    }

    private func release() {
        imageViews.values.forEach { $0.removeFromSuperview() }
        imageViews = [:]
        tooltips = [:]
    }
}
