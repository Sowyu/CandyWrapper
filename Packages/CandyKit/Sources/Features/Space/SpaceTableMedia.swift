import AppKit
import DesignSystem
import SpaceModel
import UniformTypeIdentifiers

/// The Table's row icons, Files & media cells and field deletes with Undo.
extension SpaceTableDocument {
    /// Where a title cell's icon sits: the icon itself, or on a hovered row without one the add-icon button at the
    /// cell's right. Nil when neither shows.
    func iconSlot(row: Int, cell: NSRect) -> NSRect? {
        guard model.rows.indices.contains(row) else { return nil }
        if SpacePageIcon.has(model.rows[row].page) { return SpaceTableCellDrawing.iconRect(in: cell) }
        guard hoverRow == row, cell.width > 120 else { return nil }
        return SpaceTableCellDrawing.addIconRect(in: cell)
    }

    func showIconPicker(_ row: Int, anchor: NSRect) {
        guard model.rows.indices.contains(row) else { return }
        let id = model.rows[row].id
        SpacePageIcon.showPicker(from: self, anchor: anchor, current: model.rows[row].page) { [weak self] choice in
            guard let self, let i = self.rowIndex[id] else { return }
            self.model.setIcon(i, choice)
        }
    }

    func setIcon(from files: [(data: Data, name: String)], row id: PageID) {
        Task { @MainActor [weak self] in
            guard let blob = await SpaceMedia.shared.add(Array(files.prefix(1))).first, let self, let i = self.rowIndex[id] else { return }
            if blob.mime.hasPrefix("image/") { self.model.setIcon(i, .image(blob)) } else { NSSound.beep() }
        }
    }

    /// Stores the files encrypted, then adds them to the cell in one change.
    func attach(_ files: [(data: Data, name: String)], row id: PageID, column columnID: String) {
        Task { @MainActor [weak self] in
            let refs = await SpaceMedia.shared.add(files)
            guard let self, let i = self.rowIndex[id], let column = self.model.columns.first(where: { $0.id == columnID }) else { return }
            self.model.addFiles(i, column, refs)
        }
    }

    func showFilesPopover(_ row: Int, _ column: SpaceTableModel.Column, anchor: NSRect) {
        guard let window else { return }
        let content = SpaceFilesPopover(doc: self, row: model.rows[row].id, column: column.id)
        let popover = PopoverView(content: content, padding: .none)
        let host = PopupHost.host(for: window)
        host.open(popover, trigger: self, anchorRect: anchor,
                  placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                  motion: .popover, swallowsOutsideClick: true, returnsFocus: false)
        filesPopover = content
    }

    /// Deletes at once and offers Undo in a toast; the values stay on the rows, so undo restores everything.
    func deleteField(_ id: String) {
        let name = model.name(of: id)
        model.deleteField(id)
        var v: NSView? = superview
        while let cur = v, !(cur is SpaceTableView) { v = cur.superview }
        guard let table = v as? SpaceTableView else { return }
        _ = table.toasts.show(ToastView(title: "Deleted \(name)", actionTitle: "Undo", action: { [weak self] in self?.undo(nil) }))
    }
}

extension SpaceTableCellDrawing {
    static let thumb: CGFloat = 22
    static let thumbGap: CGFloat = 4

    static func iconRect(in cell: NSRect) -> NSRect { NSRect(x: cell.minX + pad - 1, y: cell.midY - 9, width: 18, height: 18) }
    static func addIconRect(in cell: NSRect) -> NSRect { NSRect(x: cell.maxX - 28, y: cell.midY - 10, width: 20, height: 20) }

    /// Thumbnails for images and a paperclip tile for other files, as many as fit, then "+N".
    static func drawFiles(_ refs: [BlobReference], in rect: NSRect) {
        let fit = visibleThumbs(refs.count, width: rect.width)
        var x = rect.minX + pad
        for ref in refs.prefix(fit) {
            let r = NSRect(x: x, y: rect.midY - thumb / 2, width: thumb, height: thumb)
            drawThumb(ref, in: r, radius: 4)
            x += thumb + thumbGap
        }
        if fit < refs.count {
            text("+\(refs.count - fit)", in: NSRect(x: x - 2, y: rect.minY, width: 40, height: rect.height), color: Themed.color(\.mutedForeground), font: DSFont.ui(12, weight: .medium), pad: 2)
        }
    }

    static func visibleThumbs(_ count: Int, width: CGFloat) -> Int {
        let room = width - 2 * pad
        let all = Int((room + thumbGap) / (thumb + thumbGap))
        return all >= count ? count : max(0, Int((room - 28 + thumbGap) / (thumb + thumbGap)))
    }

    /// Which thumbnail an x offset in the cell lands on.
    static func thumbIndex(_ refs: [BlobReference], at x: CGFloat, width: CGFloat) -> Int? {
        let local = x - pad
        guard local >= 0 else { return nil }
        let i = Int(local / (thumb + thumbGap))
        guard i < visibleThumbs(refs.count, width: width), local - CGFloat(i) * (thumb + thumbGap) <= thumb else { return nil }
        return i
    }

    static func drawThumb(_ ref: BlobReference, in r: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if ref.mime.hasPrefix("image/"), let image = SpaceMedia.shared.thumbnail(ref) {
            // Cover the square, like Notion's gallery thumbnails.
            let s = max(r.width / max(1, image.size.width), r.height / max(1, image.size.height))
            let w = image.size.width * s, h = image.size.height * s
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Themed.color(\.foreground, 0.07).setFill()
            path.fill()
            if !ref.mime.hasPrefix("image/") {
                let g = r.width * 0.6
                icon(.paperclip, in: CGRect(x: r.midX - g / 2, y: r.midY - g / 2, width: g, height: g), color: Themed.color(\.iconMuted))
            }
        }
        Themed.color(\.foreground, 0.1).setStroke()
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// A Files & media cell opened: each file with its thumbnail, name and size, Open for images and Remove; then Add
/// files. Paste and drop work here too.
final class SpaceFilesPopover: DSView {
    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 44
    private weak var doc: SpaceTableDocument?
    private let rowID: PageID
    private let columnID: String
    private var rowViews: [SpaceFileRow] = []
    private let add = ButtonView("Add files", icon: .plus, variant: .ghost, size: .sm)
    private let hint = LabelView("or paste or drop them here", font: DSFont.ui(12), color: Themed.color(\.placeholder))
    private let empty = LabelView("No files yet", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
    private var mediaToken: NSObjectProtocol?

    init(doc: SpaceTableDocument, row: PageID, column: String) {
        self.doc = doc
        rowID = row
        columnID = column
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        add.action = { [weak self] in self?.choose() }
        hint.lineHeight = 16
        empty.lineHeight = 20
        [add, hint, empty].forEach(addSubview)
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.svg.identifier)])
        setAccessibilityLabel("Files")
        mediaToken = NotificationCenter.default.addObserver(forName: SpaceMedia.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rowViews.forEach { $0.needsDisplay = true } }
        }
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { if let mediaToken { NotificationCenter.default.removeObserver(mediaToken) } }

    private var location: (row: Int, column: SpaceTableModel.Column)? {
        guard let doc, let i = doc.rowIndex[rowID], let c = doc.model.columns.first(where: { $0.id == columnID }) else { return nil }
        return (i, c)
    }
    private var refs: [BlobReference] { location.map { doc?.model.files($0.row, $0.column) ?? [] } ?? [] }

    func refresh() {
        let refs = refs
        while rowViews.count > refs.count { rowViews.removeLast().removeFromSuperview() }
        while rowViews.count < refs.count {
            let v = SpaceFileRow()
            v.onOpen = { [weak self, weak v] in self?.open(v?.index ?? 0) }
            v.onRemove = { [weak self, weak v] in self?.remove(v?.index ?? 0) }
            addSubview(v)
            rowViews.append(v)
        }
        for (i, v) in rowViews.enumerated() { v.index = i; v.ref = refs[i] }
        empty.isHidden = !refs.isEmpty
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
        superview?.needsLayout = true
        if let popover = superview { popover.setFrameSize(popover.intrinsicContentSize) }
        needsLayout = true
    }

    private var listHeight: CGFloat { rowViews.isEmpty ? 44 : CGFloat(rowViews.count) * Self.rowHeight }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: 6 + min(listHeight, 5.5 * Self.rowHeight) + 1 + 44) }
    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        var y: CGFloat = 6
        for v in rowViews {
            v.frame = NSRect(x: 6, y: y, width: bounds.width - 12, height: Self.rowHeight)
            y += Self.rowHeight
        }
        empty.frame = NSRect(x: 16, y: 18, width: bounds.width - 32, height: 20)
        let footer = bounds.height - 40
        let aw = add.intrinsicContentSize.width
        add.frame = NSRect(x: 8, y: footer + 4, width: aw, height: 28)
        hint.frame = NSRect(x: add.frame.maxX + 4, y: footer + 10, width: bounds.width - add.frame.maxX - 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        Themed.color(\.border).setFill()
        NSRect(x: 0, y: bounds.height - 44, width: bounds.width, height: 1).fill()
    }
    override var wantsUpdateLayer: Bool { false }

    private func choose() {
        guard let window, let doc else { return }
        let row = rowID, column = columnID
        SpaceMedia.choose(in: window, images: false, multiple: true) { [weak doc] files in doc?.attach(files, row: row, column: column) }
    }

    private func open(_ i: Int) {
        guard let window else { return }
        SpaceMedia.expand(refs, index: i, in: window)
    }

    private func remove(_ i: Int) {
        guard let doc, let loc = location else { return }
        doc.model.removeFile(loc.row, loc.column, at: i)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { SpaceMedia.canRead(sender.draggingPasteboard) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = SpaceMedia.files(from: sender.draggingPasteboard)
        guard !files.isEmpty, let doc else { return false }
        doc.attach(files, row: rowID, column: columnID)
        return true
    }

    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v", let doc else {
            return super.performKeyEquivalent(with: event)
        }
        let files = SpaceMedia.files(from: .general)
        guard !files.isEmpty else { return super.performKeyEquivalent(with: event) }
        doc.attach(files, row: rowID, column: columnID)
        return true
    }
}

/// One file: a 32pt thumbnail, the name over its size, and on hover Open (images) and Remove.
final class SpaceFileRow: DSView {
    var index = 0
    var ref: BlobReference? { didSet { if ref != oldValue { refreshText() } } }
    var onOpen: () -> Void = {}
    var onRemove: () -> Void = {}
    private let name = LabelView("", font: DSFont.ui(13), color: Themed.color(\.foreground))
    private let size = LabelView("", font: DSFont.ui(11), color: Themed.color(\.mutedForeground))
    private let openButton = ButtonView(icon: .maximize2, variant: .ghost, size: .iconXs)
    private let removeButton = ButtonView(icon: .x, variant: .ghost, size: .iconXs)
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true; refreshButtons() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineHeight = 18
        name.truncation = .middle
        size.lineHeight = 14
        openButton.toolTip = "Open"
        openButton.setAccessibilityLabel("Open")
        removeButton.toolTip = "Remove"
        removeButton.setAccessibilityLabel("Remove")
        openButton.action = { [weak self] in self?.onOpen() }
        removeButton.action = { [weak self] in self?.onRemove() }
        [name, size, openButton, removeButton].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        refreshButtons()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { if ref?.mime.hasPrefix("image/") == true { onOpen() } }

    private var isImage: Bool { ref?.mime.hasPrefix("image/") == true }

    private func refreshText() {
        name.text = ref?.name ?? ""
        size.text = ref.map { ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file) } ?? ""
        setAccessibilityLabel(name.text)
        refreshButtons()
        needsDisplay = true
    }

    private func refreshButtons() {
        openButton.isHidden = !hovered || !isImage
        removeButton.isHidden = !hovered
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let right: CGFloat = hovered ? (isImage ? 56 : 30) : 8
        name.frame = NSRect(x: 50, y: bounds.midY - 17, width: bounds.width - 50 - right, height: 18)
        size.frame = NSRect(x: 50, y: bounds.midY + 2, width: bounds.width - 50 - right, height: 14)
        removeButton.frame = NSRect(x: bounds.width - 30, y: bounds.midY - 12, width: 24, height: 24)
        openButton.frame = NSRect(x: bounds.width - 56, y: bounds.midY - 12, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Themed.color(\.foreground, 0.04).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        guard let ref else { return }
        SpaceTableCellDrawing.drawThumb(ref, in: NSRect(x: 8, y: bounds.midY - 16, width: 32, height: 32), radius: 5)
    }
}
