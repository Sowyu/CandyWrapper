import AppKit
import DesignSystem
import SpaceModel
import UniformTypeIdentifiers

/// A page's icon (docs/space.md "Page record"): an emoji in `icon`, or an image in `iconImage`, which wins.
@MainActor
enum SpacePageIcon {
    enum Choice: Equatable, Sendable {
        case emoji(String)
        case image(BlobReference)
        case none
    }

    nonisolated static func has(_ page: PageRecord) -> Bool { choice(page) != .none }

    nonisolated static func choice(_ page: PageRecord) -> Choice {
        if let blob = page.iconImage { return .image(blob) }
        if let emoji = page.icon, !emoji.isEmpty { return .emoji(emoji) }
        return .none
    }

    /// Setting one kind clears the other, so every client agrees on what shows.
    nonisolated static func change(_ id: PageID, _ choice: Choice) -> RecordChange {
        switch choice {
        case .emoji(let e): RecordChange(kind: .page, id: id, set: ["icon": .string(e), "iconImage": .null])
        case .image(let blob): RecordChange(kind: .page, id: id, set: ["icon": .null, "iconImage": (try? JSONValue(encoding: blob)) ?? .null])
        case .none: RecordChange(kind: .page, id: id, set: ["icon": .null, "iconImage": .null])
        }
    }

    /// Draws the icon centered in `rect` of a flipped view. Returns false when the page has none. An image still
    /// loading draws as a faint square, and its view redraws on `SpaceMedia.didLoad`.
    @discardableResult
    static func draw(_ page: PageRecord, in rect: CGRect) -> Bool { draw(choice(page), in: rect) }

    @discardableResult
    static func draw(_ choice: Choice, in rect: CGRect) -> Bool {
        switch choice {
        case .none: return false
        case .image(let blob):
            let radius = max(2, rect.width * 0.18)
            if let image = SpaceMedia.shared.thumbnail(blob) {
                let fit = aspectFit(image.size, in: rect)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: fit, xRadius: radius, yRadius: radius).addClip()
                image.draw(in: fit, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                Themed.color(\.foreground, 0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
            return true
        case .emoji(let emoji):
            let font = NSFont.systemFont(ofSize: (rect.height * 0.86).rounded())
            let text = NSAttributedString(string: emoji, attributes: [.font: font])
            let size = text.size()
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Opens the picker under `anchor` in `view`. `pick` gets the choice and makes the change through its own undo.
    static func showPicker(from view: NSView, anchor: NSRect, current: PageRecord?, pick: @escaping @MainActor (Choice) -> Void) {
        guard let window = view.window else { return }
        let picker = SpaceIconPicker(hasIcon: current.map(has) ?? false)
        let popover = PopoverView(content: picker, padding: .none)
        let host = PopupHost.host(for: window)
        let open = host.open(popover, trigger: view, anchorRect: anchor,
                             placement: PopupPlacement(side: .bottom, align: .start, sideOffset: 4, fallbackAxisSide: .none),
                             motion: .popover, swallowsOutsideClick: true, returnsFocus: false)
        picker.onPick = { [weak host] choice in
            host?.close(open, returnFocus: false)
            pick(choice)
        }
        picker.onUpload = { [weak host, weak window] files in
            host?.close(open, returnFocus: false)
            Task { @MainActor in
                if files.isEmpty, let window {
                    SpaceMedia.choose(in: window, images: true, multiple: false) { files in
                        Task { @MainActor in if let blob = await SpaceMedia.shared.add(files).first { pick(.image(blob)) } }
                    }
                } else if let blob = await SpaceMedia.shared.add(files).first {
                    pick(.image(blob))
                }
            }
        }
        popover.onKey = { key in picker.handle(key) }
        DispatchQueue.main.async { picker.focusSearch() }
    }
}

/// One page icon drawn into its bounds; hidden while there is none. With `onClick` it's a button.
final class SpaceIconView: DSView {
    var choice: SpacePageIcon.Choice = .none {
        didSet { if choice != oldValue { needsDisplay = true; isHidden = choice == .none && !showsWhenEmpty } }
    }
    var showsWhenEmpty = false { didSet { isHidden = choice == .none && !showsWhenEmpty } }
    var onClick: (() -> Void)? { didSet { setAccessibilityRole(onClick == nil ? .image : .button) } }
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(mediaLoaded), name: SpaceMedia.didLoad, object: nil)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func mediaLoaded() { if case .image = choice { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { onClick == nil ? nil : super.hitTest(point) }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseEntered(with event: NSEvent) { hovered = onClick != nil }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            Themed.color(\.foreground, 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let inset = onClick == nil ? 0 : bounds.width * 0.1
        SpacePageIcon.draw(choice, in: bounds.insetBy(dx: inset, dy: inset))
    }
}

/// Emoji search, an emoji grid, Upload and Remove. The grid is one view that draws only the rows on screen.
final class SpaceIconPicker: DSView {
    static let width: CGFloat = 332
    let search = InputView(placeholder: "Search emoji")
    private let remove = ButtonView("Remove", variant: .ghostMuted, size: .xs)
    private let upload = ButtonView("Upload an image or SVG", icon: .upload, variant: .outline, size: .sm)
    private let scroll = NSScrollView()
    private let grid = SpaceEmojiGrid()
    private let empty = LabelView("No emoji match", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    var onPick: (SpacePageIcon.Choice) -> Void = { _ in }
    /// Empty means "open the file panel".
    var onUpload: ([(data: Data, name: String)]) -> Void = { _ in }

    init(hasIcon: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 360))
        search.setAccessibilityLabel("Search emoji")
        search.onChange = { [weak self] text in self?.filter(text) }
        search.onSubmit = { [weak self] in
            guard let self, let first = self.grid.emojis.first else { return }
            self.onPick(.emoji(first.emoji))
        }
        // Pasting an image or SVG into the search field uploads it; text pastes as text.
        search.onPaste = { [weak self] pasteboard in
            guard pasteboard.string(forType: .string) == nil else { return false }
            let files = SpaceMedia.files(from: pasteboard)
            guard !files.isEmpty else { return false }
            self?.onUpload(Array(files.prefix(1)))
            return true
        }
        remove.isHidden = !hasIcon
        remove.action = { [weak self] in self?.onPick(.none) }
        upload.action = { [weak self] in self?.onUpload([]) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = grid
        grid.onPick = { [weak self] e in self?.onPick(.emoji(e)) }
        empty.alignment = .center
        empty.isHidden = true
        [search, remove, scroll, empty, upload].forEach(addSubview)
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.svg.identifier)])
        setAccessibilityLabel("Page icon")
        filter("")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: 360) }
    override var fittingSize: NSSize { intrinsicContentSize }

    func focusSearch() { window?.makeFirstResponder(search) }

    func handle(_ key: PopupKey) -> Bool { false }

    private func filter(_ text: String) {
        grid.emojis = SpaceEmoji.search(text)
        empty.isHidden = !grid.emojis.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, pad: CGFloat = 12
        let rw = remove.isHidden ? 0 : remove.intrinsicContentSize.width + 6
        search.frame = NSRect(x: pad, y: pad, width: w - 2 * pad - rw, height: 32)
        if !remove.isHidden { remove.frame = NSRect(x: w - pad - rw + 6, y: pad + 3, width: rw - 6, height: 26) }
        let footer: CGFloat = 32 + pad
        let gridTop = pad + 32 + 8
        scroll.frame = NSRect(x: 6, y: gridTop, width: w - 12, height: bounds.height - gridTop - footer - 8)
        grid.layoutFor(width: scroll.contentSize.width)
        empty.frame = NSRect(x: 0, y: scroll.frame.midY - 8, width: w, height: 16)
        upload.frame = NSRect(x: pad, y: bounds.height - footer, width: w - 2 * pad, height: 32)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { SpaceMedia.canRead(sender.draggingPasteboard) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = SpaceMedia.files(from: sender.draggingPasteboard)
        guard !files.isEmpty else { return false }
        onUpload(Array(files.prefix(1)))
        return true
    }
}

/// The emoji cells, eight across, drawn in one pass over the visible rows.
final class SpaceEmojiGrid: DSView {
    static let cell: CGFloat = 38
    var emojis: [SpaceEmoji.Entry] = [] { didSet { hovered = nil; needsLayout = true; superview?.needsLayout = true; needsDisplay = true } }
    var onPick: (String) -> Void = { _ in }
    private var columns = 8
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true; toolTip = hovered.map { emojis[$0].name.capitalized } } } }
    private static let font = NSFont.systemFont(ofSize: 24)

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Emoji")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func layoutFor(width: CGFloat) {
        columns = max(1, Int(width / Self.cell))
        let rows = (emojis.count + columns - 1) / columns
        setFrameSize(NSSize(width: width, height: CGFloat(rows) * Self.cell))
    }

    private func rect(_ i: Int) -> CGRect {
        let inset = (bounds.width - CGFloat(columns) * Self.cell) / 2
        return CGRect(x: inset + CGFloat(i % columns) * Self.cell, y: CGFloat(i / columns) * Self.cell, width: Self.cell, height: Self.cell)
    }

    private func index(at p: NSPoint) -> Int? {
        let inset = (bounds.width - CGFloat(columns) * Self.cell) / 2
        let c = Int((p.x - inset) / Self.cell), r = Int(p.y / Self.cell)
        guard p.x >= inset, c < columns, p.y >= 0 else { return nil }
        let i = r * columns + c
        return emojis.indices.contains(i) ? i : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let first = max(0, Int(dirtyRect.minY / Self.cell)) * columns
        let last = min(emojis.count, (Int(dirtyRect.maxY / Self.cell) + 1) * columns)
        guard first < last else { return }
        for i in first..<last {
            let r = rect(i)
            if i == hovered {
                Themed.color(\.accent).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            let s = NSAttributedString(string: emojis[i].emoji, attributes: [.font: Self.font])
            let size = s.size()
            s.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onPick(emojis[i].emoji) }
    }
}

/// Every single-scalar emoji the system draws in color, named by Unicode, smileys first.
enum SpaceEmoji {
    struct Entry: Equatable {
        var emoji: String
        var name: String
    }

    private static let ranges: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1F440...0x1F4FF, 0x1F300...0x1F43F, 0x1F500...0x1F5FF,
        0x1F680...0x1F6FF, 0x1FA70...0x1FAFF, 0x2600...0x27BF, 0x1F900...0x1F90F,
    ]

    static let all: [Entry] = {
        var seen = Set<UInt32>(), out: [Entry] = []
        for range in ranges {
            for v in range where seen.insert(v).inserted {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, !s.properties.isEmojiModifier,
                      let name = s.properties.name else { continue }
                out.append(Entry(emoji: String(Character(s)), name: name.lowercased()))
            }
        }
        return out
    }()

    /// Every word of the query must start a word of the name, so "red app" finds the red apple.
    static func search(_ query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { e in
            let parts = e.name.split(whereSeparator: { $0 == " " || $0 == "-" })
            return words.allSatisfy { w in parts.contains { $0.hasPrefix(w) } }
        }
    }
}
