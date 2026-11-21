import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Your images and videos as their own shape, outside the bubble (TimelineUserMessageRow.tsx:732-836 at 4928, #27306,
/// #38558). A lone image is 192pt tall at its own width, 96pt at least and the lane's 80% at most, shown whole. Two or
/// more images share a 320pt collage split by 1pt hairlines. A single video is 320pt at 4:3, and a mix sits in a 320pt
/// two-column grid of 4:3 cells. Every shape is `rounded-2xl` with an inset hairline, and the corners that meet the
/// bubble or a neighbouring message tighten to 6pt.
final class UserMediaBlockView: DSView {
    static let loneHeight: CGFloat = 192, minWidth: CGFloat = 96, width: CGFloat = 320

    private var images: [JSONValue] = []
    private var videos: [JSONValue] = []
    private var cells: [AsyncImageView] = []
    private var videoViews: [ThreadMediaAttachmentView] = []
    private let clip = DSView()
    private let ring = CAShapeLayer()
    private weak var model: ThreadViewModel?
    var joinedTop = false { didSet { if joinedTop != oldValue { needsLayout = true } } }
    var joinedBottom = false { didSet { if joinedBottom != oldValue { needsLayout = true } } }
    /// The lone image's width changed once its pixels arrived.
    var onNaturalWidthChange: (() -> Void)?

    /// Image aspect ratios by attachment id, so a recycled row lays out at the right width before it decodes.
    @MainActor private static var aspects: [String: CGFloat] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(clip)
        ring.fillColor = nil
        ring.lineWidth = 1
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var lone: Bool { videos.isEmpty && images.count == 1 }
    private var collage: Bool { videos.isEmpty && images.count > 1 && images.allSatisfy { $0["source"]?["kind"]?.stringValue != "snap-shot" } }

    func configure(images: [JSONValue], videos: [JSONValue], model: ThreadViewModel?) {
        self.model = model
        guard images != self.images || videos != self.videos else { return }
        self.images = images
        self.videos = videos
        rebuild()
    }

    private func rebuild() {
        cells.forEach { $0.removeFromSuperview() }
        videoViews.forEach { $0.releasePlayer(); $0.removeFromSuperview() }
        let loader = model?.attachmentImage
        cells = images.map { image in
            let cell = AsyncImageView()
            cell.cacheable = true
            // A lone image shows whole (`object-contain`); collage and grid cells crop to fill.
            cell.cover = !lone
            cell.fallback.font = DSFont.ui(11)
            let id = image["id"]?.stringValue ?? "", name = image["name"]?.stringValue ?? "image"
            cell.set(key: id, fallbackText: name, loader: loader.map { load in { side in await load(id, side, true) } })
            if let loader {
                cell.onContextMenu = { event, view in
                    MediaAttachmentContextMenu.show(name: name, load: { side in await loader(id, side, false) }, event: event, view: view)
                }
            }
            cell.onLoad = { [weak self, weak cell] in
                guard let self, let image = cell?.image, image.height > 0 else { return }
                let aspect = CGFloat(image.width) / CGFloat(image.height)
                guard Self.aspects[id] != aspect else { return }
                Self.aspects[id] = aspect
                if self.lone { self.onNaturalWidthChange?() }
            }
            cell.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(expand(_:))))
            cell.setAccessibilityLabel("Preview \(name)")
            if let source = image["source"], source["kind"]?.stringValue == "snap-shot" {
                cell.addSubview(SnapShotAttachmentDetailsView(source: source))
            }
            clip.addSubview(cell)
            return cell
        }
        videoViews = videos.map { value in
            let view = ThreadMediaAttachmentView(id: value["id"]?.stringValue ?? "", name: value["name"]?.stringValue ?? "", audio: false,
                                                 loader: model?.attachmentMediaURL, playback: model?.audioPlayback,
                                                 onOpen: { [weak self] in self?.model?.onOpenAttachment?(value, false) })
            clip.addSubview(view)
            return view
        }
        needsLayout = true
        needsDisplay = true
    }

    @objc private func expand(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view, let index = cells.firstIndex(where: { $0 === view }), let loader = model?.attachmentImage else { return }
        let items = images.enumerated().map { i, image in
            let id = image["id"]?.stringValue ?? ""
            return ExpandedImagePreviewView.Item(key: id, name: image["name"]?.stringValue ?? "image",
                                                 source: image["source"].flatMap { $0["kind"]?.stringValue == "snap-shot" ? $0 : nil }, cacheable: true,
                                                 load: { side in await loader(id, side, false) })
                .withPreview(from: cells[i])
        }
        model?.onExpandImage?(items, index)
    }

    func setMediaVisible(_ visible: Bool) { videoViews.forEach { $0.setVisible(visible) } }

    /// The block's size in a lane that leaves it `maxWidth`.
    func size(maxWidth: CGFloat) -> CGSize {
        let count = images.count + videos.count
        guard count > 0 else { return .zero }
        if lone {
            // `h-48 w-auto min-w-24 max-w-full`; before the pixels arrive the image is its 96pt minimum, as in T3.
            let aspect = images[0]["id"]?.stringValue.flatMap { Self.aspects[$0] }
            let natural = aspect.map { $0 * Self.loneHeight } ?? Self.minWidth
            return CGSize(width: min(maxWidth, max(Self.minWidth, ceil(natural))), height: Self.loneHeight)
        }
        let width = min(maxWidth, Self.width)
        return CGSize(width: width, height: frames(width: width).map(\.maxY).max() ?? 0)
    }

    /// Each image's frame, then each video's, in a block `width` wide (all but the lone image).
    private func frames(width w: CGFloat) -> [CGRect] {
        let n = images.count
        if collage {
            switch n {
            case 2:
                // `auto-rows-[12rem] grid-cols-2 gap-px`.
                let cw = (w - 1) / 2
                return [CGRect(x: 0, y: 0, width: cw, height: 192), CGRect(x: cw + 1, y: 0, width: cw, height: 192)]
            case 3:
                // `auto-rows-[calc(6rem-0.5px)] grid-cols-[3fr_2fr]`, the first spanning both rows.
                let a = (w - 1) * 3 / 5, b = (w - 1) * 2 / 5, h: CGFloat = 95.5
                return [CGRect(x: 0, y: 0, width: a, height: h * 2 + 1), CGRect(x: a + 1, y: 0, width: b, height: h),
                        CGRect(x: a + 1, y: h + 1, width: b, height: h)]
            default:
                // `auto-rows-[6rem] grid-cols-2`, an odd last image across both columns.
                let cw = (w - 1) / 2
                return (0..<n).map { i in
                    let row = CGFloat(i / 2), y = row * 97
                    if n % 2 == 1, i == n - 1 { return CGRect(x: 0, y: y, width: w, height: 96) }
                    return CGRect(x: i % 2 == 0 ? 0 : cw + 1, y: y, width: cw, height: 96)
                }
            }
        }
        // One video: `w-80`, 4:3. A mix: `grid-cols-2 gap-2` of 4:3 cells, a snapshot across both columns.
        let single = n + videos.count == 1
        let cw = single ? w : (w - 8) / 2
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var result: [CGRect] = []
        func place(_ width: CGFloat, _ height: CGFloat) {
            if x > 0, x + width > w + 0.5 { x = 0; y += rowHeight + 8; rowHeight = 0 }
            result.append(CGRect(x: x, y: y, width: width, height: height))
            x += width + 8; rowHeight = max(rowHeight, height)
        }
        for image in images {
            let snapshot = image["source"]?["kind"]?.stringValue == "snap-shot"
            // ponytail: a snapshot cell uses the 4:3 width at a fixed 112pt, where T3 sizes it to the image; size it from the pixels if snapshots look off
            if snapshot { if x > 0 { x = 0; y += rowHeight + 8; rowHeight = 0 }; place(w, 112); x = 0; y += 112 + 8; rowHeight = 0 }
            else { place(cw, cw * 3 / 4) }
        }
        for _ in videos { place(cw, cw * 3 / 4) }
        return result
    }

    override func updateLayer() {
        super.updateLayer()
        let dark = effectiveAppearance.isDark
        // `after:ring-1 after:ring-inset after:ring-black/9 dark:after:ring-white/12`; the collage's hairlines show
        // its `bg-black/9 dark:bg-white/12` through the gaps.
        let edge = dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.09)
        ring.strokeColor = edge.cgColor
        clip.layer?.backgroundColor = collage ? edge.cgColor : nil
        for cell in cells { cell.layer?.backgroundColor = TL.c(\.background, collage ? 1 : 0.7).cgColor(in: self) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let size = bounds.size
        let r: CGFloat = 16, j: CGFloat = 6
        if lone || collage || images.count + videos.count == 1 {
            // One shape: clip everything to it and ring it.
            clip.frame = bounds
            if lone, let cell = cells.first { cell.frame = clip.bounds }
            else { for (view, frame) in zip(cells as [NSView] + videoViews as [NSView], frames(width: size.width)) { view.frame = frame } }
            shape(clip, rect: clip.bounds, r: r, j: j)
            ring.isHidden = false
            ring.frame = bounds
            ring.path = FillView.roundedPath(bounds.insetBy(dx: 0.5, dy: 0.5), topLeft: r - 0.5, topRight: (joinedTop ? j : r) - 0.5,
                                             bottomRight: (joinedBottom ? j : r) - 0.5, bottomLeft: r - 0.5, flipped: isFlipped)
        } else {
            // A grid: each cell is its own rounded shape.
            clip.frame = bounds
            clip.layer?.mask = nil
            clip.layer?.cornerRadius = 0
            ring.isHidden = true
            for (view, frame) in zip(cells as [NSView] + videoViews as [NSView], frames(width: size.width)) {
                view.frame = frame
                view.wantsLayer = true
                view.layer?.cornerRadius = r
                view.layer?.masksToBounds = true
            }
        }
        for cell in cells {
            for view in cell.subviews where view is SnapShotAttachmentDetailsView {
                view.frame = NSRect(x: 0, y: cell.bounds.height - 60, width: cell.bounds.width, height: 60)
            }
        }
    }

    /// Rounds `view` to the block's shape. A joined corner needs a mask, which `render(in:)` snapshots don't draw;
    /// on screen it shows.
    // ponytail: offscreen snapshots show joined media corners at 16pt; draw the image into a shape layer if a fidelity case needs them
    private func shape(_ view: NSView, rect: CGRect, r: CGFloat, j: CGFloat) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.masksToBounds = true
        if joinedTop || joinedBottom {
            layer.cornerRadius = 0
            let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.frame = layer.bounds
            mask.path = FillView.roundedPath(layer.bounds, topLeft: r, topRight: joinedTop ? j : r, bottomRight: joinedBottom ? j : r,
                                             bottomLeft: r, flipped: view.isFlipped)
            layer.mask = mask
        } else {
            layer.mask = nil
            layer.cornerRadius = r
        }
    }
}

/// `UserFileCard` (TimelineUserMessageRow.tsx:109-196 at 4928, #27324, #27377): a file sent without words.
/// `w-64 rounded-2xl bg-message py-2 ps-2 pe-1`, a 36pt `rounded-lg bg-background/60` icon tile, the name in
/// `text-sm font-medium`, "PDF · 1.2 KB" (or the size alone for pasted text, or "Sending…") in muted `text-xs`,
/// and a download button. 52pt tall.
final class UserFileCardView: DSView {
    static let width: CGFloat = 256, height: CGFloat = 52
    var onOpen: ((Bool) -> Void)?
    private let card = FillView()
    private let tile = FillView()
    private let icon: IconView
    private let name: LabelView
    private let detail: LabelView
    private let preview = ControlView()
    private let download = ButtonView(icon: .download, variant: .ghostMuted, size: .iconXs)

    init(file: JSONValue) {
        let fileName = file["name"]?.stringValue ?? "Attachment"
        let label = UserMessageShape.fileLabel(file)
        let meta = FileLinkMeta(filePath: fileName, targetPath: fileName, workspaceRelativePath: fileName, basename: fileName, line: nil, column: nil)
        let (definition, color) = FileChipStyle.icon(for: meta)
        icon = IconView(definition: definition, size: 16, color: color)
        name = LabelView(label, font: DSFont.ui(14, weight: .medium), color: TL.c(\.foreground))
        name.lineHeight = 20
        let sending = file["downloadable"]?.boolValue == false
        let pasted = file["source"]?["_tag"]?.stringValue == "pasted-text"
        let ext = fileName.firstMatch(of: /\.([A-Za-z0-9]{1,8})$/).map { String($0.1).uppercased() } ?? "File"
        let size = StorageCleanupReport.formatBytes(file["sizeBytes"]?.doubleValue ?? 0)
        detail = LabelView(sending ? "Sending…" : pasted ? size : "\(ext) · \(size)", font: TL.tabular(12), color: TL.c(\.mutedForeground))
        detail.lineHeight = 16
        super.init(frame: .zero)
        card.fill = TL.c(\.messageSurface)
        card.radius = 16
        tile.fill = TL.c(\.background, 0.6)
        tile.radius = 8
        addSubview(card)
        addSubview(preview)
        [tile, icon, name, detail].forEach { preview.addSubview($0) }
        addSubview(download)
        preview.setAccessibilityLabel("Preview " + label)
        download.setAccessibilityLabel(sending ? "Sending attachment" : "Download " + label)
        download.setTooltip(sending ? nil : "Download " + label)
        preview.isEnabled = !sending
        download.isEnabled = !sending
        preview.action = { [weak self] in self?.onOpen?(false) }
        download.action = { [weak self] in self?.onOpen?(true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        card.frame = bounds
        // `ps-2 pe-1`, the identity then `gap-1` and the 24pt button.
        preview.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 8 - 4 - 24 - 4), height: 36)
        tile.frame = NSRect(x: 0, y: 0, width: 36, height: 36)
        icon.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        let textX: CGFloat = 36 + 12, textWidth = max(0, preview.bounds.width - textX)
        name.frame = NSRect(x: textX, y: 0, width: textWidth, height: 20)
        detail.frame = NSRect(x: textX, y: 20, width: textWidth, height: 16)
        download.frame = NSRect(x: bounds.width - 4 - 24, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
}
