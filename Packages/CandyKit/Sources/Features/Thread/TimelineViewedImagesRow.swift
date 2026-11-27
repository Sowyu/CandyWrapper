import AppKit
import DesignSystem
import T3Store

/// `ViewedImagesTimelineRow` (4928 chat/TimelineWorkEntryRow.tsx:250-282, #30473): the images a tool group opened,
/// below the group whether it is folded or open, `flex flex-wrap items-start gap-2 px-0.5` in `pb-2`. Each is a
/// `ChatMarkdownAssetImage` at most 10rem tall. Clicking one opens the viewer on all of them (#34333).
/// A file that fails to load leaves the row, as viewed files do in open work rows here. An image only a running read
/// opened holds the loading frame without asking for the file, which may not exist yet (5258
/// TimelineWorkEntryRow.tsx:265-278, `pending` in ChatMarkdownMedia.tsx:411-440, #42921).
final class ViewedImagesRowView: TimelineRowView {
    static let maxHeight: CGFloat = 160
    private static let gap: CGFloat = 8
    private static let inset: CGFloat = 2

    private var images: [WorkImage] = []
    private var pending: Set<String> = []
    private var imageViews: [String: AsyncImageView] = [:]
    private var contentVisible = true

    override func configure(_ item: TimelineItem) {
        super.configure(item)
        guard case .viewedImages(let paths, let pendingPaths) = item.row.kind else { return }
        let root = context?.workspaceRoot
        pending = []
        images = paths.compactMap { path in
            guard case .workspaceFile(let file) = MarkdownImageSource.classify(path, workspaceRoot: root) else { return nil }
            let image = WorkImage.file(file, workspaceRoot: root)
            if pendingPaths.contains(path) { pending.insert(image.key) }
            return image
        }
        needsLayout = true
    }

    /// The images still shown: a failed file takes no space. A pending one never failed, since nothing asked for it.
    private var shown: [WorkImage] { images.filter { pending.contains($0.key) || !MarkdownImages.failed.contains($0.key) } }

    /// `ChatMarkdownImage`: a 16:9 slot until the size is known, then the image's box with its 1px frame. The slot is
    /// `unsizedImageFrameStyle` (ChatMarkdownMedia.tsx:92-95): `min(100%, 30rem, 10rem * 16 / 9)` wide, so it stays
    /// 16:9 at the 10rem cap.
    private func box(_ image: WorkImage, width: CGFloat) -> (size: CGSize, settled: Bool) {
        if !pending.contains(image.key), let natural = MarkdownImages.sizes[image.key] {
            return (MarkdownImages.displaySize(natural: natural, maxWidth: width, border: 1, maxHeight: Self.maxHeight), true)
        }
        let w = min(width, MarkdownStyle.imageMaxWidth, Self.maxHeight * 16 / 9)
        return (CGSize(width: w, height: w * 9 / 16), false)
    }

    /// Wraps the boxes into lines like `flex-wrap items-start`.
    private func frames(width: CGFloat) -> [(image: WorkImage, frame: CGRect, settled: Bool)] {
        let inner = max(1, width - 2 * Self.inset)
        var out: [(WorkImage, CGRect, Bool)] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for image in shown {
            let (size, settled) = box(image, width: inner)
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
            let isPending = pending.contains(image.key)
            // A pending image gets its own view, so the one that loads once the read ends starts fresh.
            let viewKey = isPending ? "pending:" + image.key : image.key
            kept.insert(viewKey)
            let view = imageViews[viewKey] ?? make(image)
            imageViews[viewKey] = view
            view.frame = settled ? frame.insetBy(dx: 1, dy: 1) : frame
            view.layer?.cornerRadius = settled ? 9 : 10
            view.requestedSide = Int((max(min(bounds.width, MarkdownStyle.imageMaxWidth), Self.maxHeight) * (window?.backingScaleFactor ?? 2)).rounded(.up))
            // `bg-muted/60 rounded-lg border border-border/40` until pixels arrive (ChatMarkdownMedia.tsx:31,177-181).
            // Redesign shows its loading skeleton there instead, as its Markdown images do.
            let redesign = ThemeRuntime.isDither(dark: effectiveAppearance.isDark)
            view.skeleton = redesign
            view.layer?.backgroundColor = settled || redesign ? nil : Themed.color(\.muted, 0.6).cgColor(in: self)
            view.layer?.borderColor = Themed.color(\.border, 0.4).cgColor(in: self)
            view.layer?.borderWidth = settled || redesign ? 0 : 1
            view.set(key: viewKey, fallbackText: "", loader: isPending ? Self.held : image.loader)
            MediaPriority.mark(image.key, view: view, visible: true)
            view.setAccessibilityLabel(isPending ? "Loading image" : "Preview " + image.alt)
        }
        for (key, view) in imageViews where !kept.contains(key) {
            view.removeFromSuperview(); imageViews[key] = nil
        }
        window?.invalidateCursorRects(for: self)
    }

    /// A pending image's loader: it never asks for the file and holds the loading state until the read ends and the
    /// view is replaced, which cancels it. The one long sleep never wakes while idle.
    private static let held: AsyncImageView.Loader = { _ in try? await Task.sleep(for: .seconds(31_536_000)); return nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func make(_ image: WorkImage) -> AsyncImageView {
        let view = AsyncImageView()
        view.cover = false
        view.cacheable = image.cacheable
        view.fallback.color = Themed.color(\.mutedForeground)
        view.fallback.font = DSFont.ui(12)
        view.setAccessibilityRole(.button)
        // No path tooltip on hover, at the user's request (2026-11-21). Right-click still reveals and copies the file.
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expand(_:))))
        view.onLoad = { [weak self, weak view] in
            guard let self, let view, let key = view.key, self.imageViews[key] === view else { return }
            guard view.image == nil else { self.window?.invalidateCursorRects(for: self); return }
            MarkdownImages.failed.insert(key)
            NotificationCenter.default.post(name: MarkdownImages.didMeasure, object: nil, userInfo: ["key": key])
            self.needsLayout = true
        }
        view.onContextMenu = { [weak self, weak view] event, source in
            guard let self, let key = view?.key, !key.hasPrefix("pending:"), let image = self.images.first(where: { $0.key == key }) else { return }
            var openFile: (() -> Void)?
            if case .file(_, let relative?)? = image.reference, let open = MarkdownImages.openInFileViewer { openFile = { open(relative) } }
            MediaAttachmentContextMenu.show(name: image.alt, load: image.loader, event: event, view: source, reference: image.reference, openFile: openFile)
        }
        addSubview(view)
        return view
    }

    @objc private func expand(_ gesture: NSClickGestureRecognizer) {
        guard let window, let view = gesture.view as? AsyncImageView, view.image != nil, let key = view.key else { return }
        let gallery = shown.filter { !pending.contains($0.key) }
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
        pending = []
    }

    private func release() {
        for (key, view) in imageViews where !key.hasPrefix("pending:") { MediaPriority.mark(key, view: view, visible: false) }
        imageViews.values.forEach { $0.removeFromSuperview() }
        imageViews = [:]
    }
}
