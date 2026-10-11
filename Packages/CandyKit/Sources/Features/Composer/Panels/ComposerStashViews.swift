import AppKit
import DesignSystem
import T3Store

/// The stash count tab on the right of the composer's dock (chat/ComposerStashBadge.tsx):
/// `ComposerBanner.Root density="comfortable" width="content"`, one row that is a button with the
/// bookmark icon, "Stash" and the count. It hides at zero. After a stash it lifts to full
/// opacity and the count turns `text-primary` for 1.2 s (`pulsing`).
public final class ComposerStashBadgeView: ComposerBannerView {
    public var count = 0 { didSet { if count != oldValue { countLabel.text = "\(count)"; needsLayout = true; restyle() } } }
    public var menuOpen = false { didSet { if menuOpen != oldValue { restyle() } } }
    public var pulsing = false { didSet { if pulsing != oldValue { restyle() } } }
    public var onToggleMenu: (() -> Void)?

    /// A stash: the badge lifts and the count remounts (`key={pulseKey}`), so its `starting:` style
    /// replays: up from 2pt lower and in from transparent, 180 ms ease-out (ComposerStashBadge.tsx:24-34).
    /// One animation per stash, nothing while idle.
    public func pulse() {
        pulsing = true
        guard window != nil, !Motion.reduced, let layer = countLabel.layer else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 2
        rise.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        for a in [rise, fade] {
            a.duration = 0.18
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.2, 1)
            layer.add(a, forKey: "pulse." + a.keyPath!)
        }
    }

    static let padY: CGFloat = 5, padX: CGFloat = 4, row: CGFloat = 24
    private let row = BannerRowButton()
    private let icon = IconView(name: .bookmark, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let title = glassLabel("Stash", font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let countLabel = glassLabel("0", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)

    public init() {
        super.init(variant: .neutral)
        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(countLabel)
        row.action = { [weak self] in self?.onToggleMenu?() }
        row.onHover = { [weak self] _ in self?.restyle() }
        addSubview(row)
        restyle()
    }

    /// `w-fit`: padding, the 24pt icon column, `gap-x-1`, the label, `gap-x-1`, the count.
    public var preferredWidth: CGFloat {
        Self.padX * 2 + Self.row + 4 + ceil(title.textWidth) + 4 + max(Self.row, ceil(countLabel.textWidth))
    }
    public var preferredHeight: CGFloat { Self.padY * 2 + Self.row + Self.overlap }

    private func restyle() {
        let strong = menuOpen || pulsing || row.state.hovered
        // `transition-colors duration-200` on the row (ComposerStashBadge.tsx:49).
        Motion.transitioning(window == nil ? [] : .colors, duration: 0.2) {
            title.color = strong ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        }
        // The count has its own color class outside the row's `transition-colors`: it switches at once.
        countLabel.color = pulsing ? Themed.color(\.primary) : Themed.color(\.mutedForeground)
        row.setAccessibilityLabel("Stashed prompts: \(count). Open stash.")
    }

    public override func layout() {
        super.layout()
        row.frame = NSRect(x: Self.padX, y: Self.padY, width: max(0, bounds.width - 2 * Self.padX), height: Self.row)
        icon.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
        title.frame = NSRect(x: 28, y: 4, width: ceil(title.textWidth), height: 16)
        let cw = ceil(countLabel.textWidth), box = max(Self.row, cw)
        countLabel.frame = NSRect(x: row.bounds.width - box + (box - cw) / 2, y: 4, width: cw, height: 16)
    }
}

/// A banner row that is a whole button (`ComposerBanner.Row render={<button/>}`): no fill of its own.
final class BannerRowButton: ControlView {
    var onHover: ((Bool) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scalesWhenPressed = false
        setAccessibilityRole(.button)
    }
    override func stateDidChange(from old: State) {
        super.stateDidChange(from: old)
        if old.hovered != state.hovered { onHover?(state.hovered) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The stash list (chat/ComposerStashMenu.tsx), docked on the composer's top edge where the `/`
/// menu goes: a header row ("Stash", the count, the open chevron) that closes it, then one row per
/// entry with the snippet, image and file markers, the relative time and a delete button. The
/// highlighted row is `bg-accent`; the mouse moves the highlight.
public final class ComposerStashMenuView: ComposerBannerView {
    public var entries: [PromptStashEntry] = [] { didSet { if entries != oldValue { rebuild() } } }
    public private(set) var highlightedId: String?
    /// `composer.stash` as a label for the empty text, or nil when unbound.
    public var shortcutLabel: String? { didSet { rebuild() } }
    /// Rebuilds the rows (relative times) when the menu opens.
    public func reload() { rebuild() }
    /// The stash's own directory, for the 16pt image markers.
    public var imageURL: ((PromptStashEntry.Image) -> URL)?
    public var onRestore: ((PromptStashEntry) -> Void)?
    public var onDelete: ((PromptStashEntry) -> Void)?
    public var onClose: (() -> Void)?
    /// Clock for the relative times (tests pin it).
    public var nowMs: () -> Int64 = { TimestampFormat.nowMs() }

    static let pad: CGFloat = 4, row: CGFloat = 24, maxList: CGFloat = 384

    private let header = BannerRowButton()
    private let headerIcon = IconView(name: .bookmark, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let headerTitle = glassLabel("Stash", font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let headerCount = glassLabel("0", font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let chevron = IconView(name: .chevronDown, size: 14, strokeColor: Themed.color(\.contrastMutedForeground))
    private let list = StashListDocument()
    private lazy var scroll = ScrollAreaView(documentView: list, scrollFade: true)
    private var rows: [StashRowView] = []
    private let empty = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)

    public init() {
        super.init(variant: .neutral)
        header.addSubview(headerIcon)
        header.addSubview(headerTitle)
        header.addSubview(headerCount)
        header.addSubview(chevron)
        header.setAccessibilityLabel("Close stash")
        header.action = { [weak self] in self?.onClose?() }
        addSubview(header)
        scroll.scrollView.automaticallyAdjustsContentInsets = false
        addSubview(scroll)
        list.addSubview(empty)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Stashed prompts")
    }

    private var listHeight: CGFloat {
        let n = CGFloat(max(1, entries.count))
        return entries.isEmpty ? 20 : n * Self.row + (n - 1)
    }

    /// Height with the 17pt overlap; the list scrolls past `min(24rem, 40dvh)`.
    public func preferredHeight(maxList: CGFloat = 384) -> CGFloat {
        Self.pad * 2 + Self.row + min(maxList, listHeight) + Self.overlap
    }

    private func rebuild() {
        headerCount.text = "\(entries.count)"
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.map { entry in
            let row = StashRowView(entry: entry, imageURL: imageURL, nowMs: nowMs())
            row.onHover = { [weak self] in self?.highlight(entry.id) }
            row.onRestore = { [weak self] in self?.onRestore?(entry) }
            row.onDelete = { [weak self] in self?.onDelete?(entry) }
            list.addSubview(row)
            return row
        }
        empty.isHidden = !entries.isEmpty
        empty.text = "Nothing stashed yet." + (shortcutLabel.map { " Press \($0) with a prompt in the composer to stash it." } ?? "")
        if highlightedId == nil || !entries.contains(where: { $0.id == highlightedId }) { highlightedId = entries.first?.id }
        updateHighlight()
        needsLayout = true
    }

    func highlight(_ id: String) {
        guard id != highlightedId else { return }
        highlightedId = id
        updateHighlight()
    }

    private func updateHighlight() { for row in rows { row.highlighted = row.entry.id == highlightedId } }

    /// The menu's keys (`ComposerStashMenu` capture listener): arrows wrap, Return restores,
    /// Cmd+Backspace deletes, Escape closes. Returns true when used.
    public func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 53: onClose?(); return true
        case 125, 126:
            guard !entries.isEmpty else { return false }
            let current = entries.firstIndex { $0.id == highlightedId }
            let offset = event.keyCode == 125 ? 1 : -1
            let base = current ?? (offset == 1 ? -1 : 0)
            let next = (base + offset + entries.count) % entries.count
            highlight(entries[next].id)
            if let row = rows[safe: next] { scroll.scrollView.contentView.scrollToVisible(row.frame) }
            return true
        case 36, 76:
            guard let entry = entries.first(where: { $0.id == highlightedId }) ?? entries.first else { return false }
            onRestore?(entry)
            return true
        case 51 where !mods.intersection([.command, .control]).isEmpty:
            guard let entry = entries.first(where: { $0.id == highlightedId }) ?? entries.first else { return false }
            onDelete?(entry)
            return true
        default: return false
        }
    }

    public override func layout() {
        super.layout()
        let w = bounds.width, inner = max(0, w - 2 * Self.pad)
        header.frame = NSRect(x: Self.pad, y: Self.pad, width: inner, height: Self.row)
        headerIcon.frame = NSRect(x: 6, y: 6, width: 12, height: 12)
        headerTitle.frame = NSRect(x: 28, y: 4, width: ceil(headerTitle.textWidth), height: 16)
        // Actions (`gap-1`): the count centered in 24, then the 24pt toggle box with its 14pt chevron.
        let cw = ceil(headerCount.textWidth)
        headerCount.frame = NSRect(x: inner - 24 - 4 - 24 + (24 - cw) / 2, y: 4, width: cw, height: 16)
        chevron.frame = NSRect(x: inner - 24 + 5, y: 5, width: 14, height: 14)
        let visible = max(0, bounds.height - Self.overlap - Self.pad * 2 - Self.row)
        scroll.frame = NSRect(x: Self.pad, y: Self.pad + Self.row, width: inner, height: visible)
        list.frame = NSRect(x: 0, y: 0, width: inner, height: listHeight)
        empty.frame = NSRect(x: 28, y: 2, width: max(0, inner - 28 - 8), height: 16)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(i) * (Self.row + 1), width: inner, height: Self.row)
        }
    }
}

private final class StashListDocument: NSView {
    override var isFlipped: Bool { true }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One stash row: the file-text icon, the snippet (`text-foreground/80`, truncated), then
/// `saving N images…` or `N images dropped` (`text-warning-foreground`), up to three 16pt image
/// markers overlapping by 6, the file count, the relative time and the delete button.
private final class StashRowView: DSView {
    let entry: PromptStashEntry
    var highlighted = false { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var onRestore: (() -> Void)?
    var onDelete: (() -> Void)?
    private let icon = IconView(name: .fileText, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let snippet = glassLabel(font: DSFont.ui(12), color: Themed.color(\.foreground, 0.8), lineHeight: 16)
    private let note = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private var thumbs: [AsyncImageView] = []
    private let fileIcon = IconView(name: .file, size: 12, strokeColor: Themed.color(\.mutedForeground))
    private let fileCount = glassLabel(font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let time = glassLabel(font: TL.tabular(12), color: Themed.color(\.mutedForeground), lineHeight: 16)
    private let delete = ButtonView(nil, icon: .x, variant: .ghost, size: .iconXs)
    private var trackingArea: NSTrackingArea?

    init(entry: PromptStashEntry, imageURL: ((PromptStashEntry.Image) -> URL)?, nowMs: Int64) {
        self.entry = entry
        super.init(frame: .zero)
        layer?.cornerRadius = 4
        snippet.text = entry.snippet
        if let pending = entry.pendingImageCount, pending > 0 {
            note.text = "saving \(pending) image\(pending == 1 ? "" : "s")…"
        } else if entry.missingImageCount > 0 {
            let n = entry.missingImageCount
            note.text = "\(n) image\(n == 1 ? "" : "s") dropped"
            note.color = Themed.color(\.warningForeground)
        }
        note.isHidden = note.text.isEmpty
        for image in entry.attachments.prefix(3) {
            let thumb = AsyncImageView()
            thumb.layer?.cornerRadius = 4
            thumb.layer?.borderWidth = 1
            if let url = imageURL?(image) {
                thumb.set(key: url.path, fallbackText: "") { side in await ComposerImageIO.thumbnail(url, side: side, cover: true) }
            }
            thumbs.append(thumb)
        }
        let files = entry.files?.count ?? 0
        fileIcon.isHidden = files == 0
        fileCount.isHidden = files == 0
        fileCount.text = "\(files)"
        time.text = TimestampFormat.formatRelativeTimeLabel(entry.createdAt, nowMs: nowMs)
        delete.iconSize = 14
        delete.smoothsFont = false
        delete.setAccessibilityLabel("Delete stashed prompt")
        delete.action = { [weak self] in self?.onDelete?() }
        [icon, snippet, note, fileIcon, fileCount, time].forEach(addSubview)
        thumbs.forEach(addSubview)  // later markers paint over earlier ones
        addSubview(delete)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Restore stashed prompt: \(entry.snippet)")
    }

    override func updateLayer() {
        layer?.backgroundColor = highlighted ? Themed.color(\.accent).cgColor(in: self) : nil
        for t in thumbs { t.layer?.borderColor = Themed.color(\.border, 0.7).cgColor(in: self) }
    }

    override func layout() {
        super.layout()
        let h = bounds.height, mid = h / 2
        icon.frame = NSRect(x: 6, y: mid - 6, width: 12, height: 12)
        // Actions right to left, `gap-1`.
        var right = bounds.width
        right -= 24
        delete.frame = NSRect(x: right, y: mid - 12, width: 24, height: 24)
        func place(_ v: NSView, _ width: CGFloat, _ height: CGFloat = 16) {
            right -= 4 + width
            v.frame = NSRect(x: right, y: mid - height / 2, width: width, height: height)
        }
        place(time, ceil(time.textWidth))
        if !fileCount.isHidden {
            let w = 12 + 4 + ceil(fileCount.textWidth)
            place(fileCount, w)
            fileIcon.frame = NSRect(x: fileCount.frame.minX, y: mid - 6, width: 12, height: 12)
            fileCount.frame = NSRect(x: fileCount.frame.minX + 16, y: mid - 8, width: ceil(fileCount.textWidth), height: 16)
        }
        if !thumbs.isEmpty {
            let w = CGFloat(thumbs.count) * 16 - CGFloat(thumbs.count - 1) * 6
            right -= 4 + w
            for (i, t) in thumbs.enumerated() { t.frame = NSRect(x: right + CGFloat(i) * 10, y: mid - 8, width: 16, height: 16) }
        }
        if !note.isHidden { place(note, ceil(note.textWidth)) }
        // Content in the 24pt icon column's neighbor, `gap-x-1` on each side.
        snippet.frame = NSRect(x: 28, y: mid - 8, width: max(0, right - 4 - 28), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { if !highlighted { onHover?() } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onRestore?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The sync row (chat/ComposerActivityStatus.tsx, `threadSyncLabel`): the spinner and
/// "Loading messages..." or "Syncing messages..." in an attached banner over the composer.
public final class ComposerActivityRowView: ComposerBannerView {
    public enum Phase: Equatable, Sendable { case loading, syncing }
    public var phase = Phase.loading { didSet { label.text = phase == .loading ? "Loading messages..." : "Syncing messages..." } }
    private let spinner = SpinnerView(size: .xs, tone: .muted)
    private let label = glassLabel("Loading messages...", font: DSFont.ui(12), color: Themed.color(\.mutedForeground), lineHeight: 16)

    public init() {
        super.init(variant: .neutral)
        addSubview(spinner)
        addSubview(label)
        label.setAccessibilityRole(.staticText)
    }

    public var preferredHeight: CGFloat { 4 + 24 + 4 + Self.overlap }

    public override func layout() {
        super.layout()
        spinner.frame = NSRect(x: 4 + 6, y: 4 + 6, width: 12, height: 12)
        label.frame = NSRect(x: 4 + 28, y: 8, width: max(0, bounds.width - 40), height: 16)
    }
}
