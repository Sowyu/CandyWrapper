import AppKit
import DesignSystem
import SpaceEngine
import SpaceModel

/// Page history (docs/space.md section 9), over the page tab: the page as it was, read only, beside the list of
/// versions. "Restore this version" hands the version to the tab, which commits it as one undoable edit.
public final class SpacePageHistoryView: DSView {
    public let store: SpaceDocumentStore
    public let page: PageID
    weak var blobs: SpaceBlobSource?
    var onClose: () -> Void = {}
    var onRestore: (SpaceVersion) -> Void = { _ in }
    private(set) var versions: [SpaceVersion] = []
    private(set) var selected: Int?
    private(set) var preview: SpacePageEditor?
    private var previewStore: SpaceReplicaStore?
    private let previewTitle = LabelView("", font: DSFont.ui(34, weight: .semibold), color: Themed.color(\.foreground))
    private let previewMeta = LabelView("", font: DSFont.ui(12), color: Themed.color(\.secondaryLabel))
    private let heading = LabelView("Page history", font: DSFont.ui(15, weight: .medium), color: Themed.color(\.foreground))
    private let note = LabelView("Loading…", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    private let list = NSScrollView()
    private let listBody = SpaceFlippedView()
    private var rows: [SpaceVersionRowView] = []
    let restore = ButtonView("Restore this version", size: .sm)
    private let close = ButtonView("Close", variant: .ghost, size: .sm)
    private let rule = CALayer()
    static let sideWidth: CGFloat = 280

    init(store: SpaceDocumentStore, page: PageID, blobs: SpaceBlobSource?) {
        self.store = store
        self.page = page
        self.blobs = blobs
        super.init(frame: .zero)
        [previewTitle, previewMeta, heading, note].forEach { $0.lineHeight = $0.font.pointSize > 20 ? 42 : 20 }
        list.documentView = listBody
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        [heading, note, list, restore, close].forEach(addSubview)
        layer?.addSublayer(rule)
        restore.isEnabled = false
        restore.action = { [weak self] in
            guard let self, let i = selected, i > 0 else { return }
            onRestore(versions[i])
        }
        close.action = { [weak self] in self?.onClose() }
        setAccessibilityLabel("Page history")
        Task { [weak self] in await self?.load() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func load() async {
        do {
            let found = try await store.history(of: page)
            versions = found
            note.text = found.isEmpty ? "No edits recorded yet." : found.count == 1 ? "1 version" : "\(found.count) versions"
        } catch {
            versions = []
            note.text = "History couldn't be read."
        }
        rows.forEach { $0.removeFromSuperview() }
        rows = versions.enumerated().map { i, v in
            let row = SpaceVersionRowView()
            row.when.text = Self.when(v.at)
            let edits = v.edits == 1 ? "1 edit" : "\(v.edits) edits"
            row.detail.text = (i == 0 ? "Current · " : "") + store.deviceLabel(v.device) + " · " + edits
            row.onPress = { [weak self] in self?.select(i) }
            listBody.addSubview(row)
            return row
        }
        needsLayout = true
        select(versions.count > 1 ? 1 : versions.isEmpty ? nil : 0)
    }

    /// Shows version `i` read only. The preview lives in a throwaway store, so nothing typed there reaches the page.
    func select(_ i: Int?) {
        selected = i
        for (n, row) in rows.enumerated() { row.isSelected = n == i }
        restore.isEnabled = (i ?? 0) > 0
        preview?.scrollView.removeFromSuperview()
        preview = nil
        previewStore = nil
        guard let i else { return }
        let v = versions[i]
        let s = SpaceReplicaStore(replica: SpaceReplica(device: DeviceID(), label: "", confirmed: v.state))
        let title = s.pages[page]?.title ?? ""
        previewTitle.text = title.isEmpty ? "Untitled" : title
        previewMeta.text = i == 0 ? "Current version" : "As it was " + Self.when(v.at).lowercasedFirst
        if s.pages[page] != nil {
            let editor = SpacePageEditor(store: s, page: page, blobs: blobs)
            editor.textView.isEditable = false
            editor.textView.setAccessibilityLabel("Page content, read only")
            editor.textView.addSubview(previewMeta)
            editor.textView.addSubview(previewTitle)
            addSubview(editor.scrollView, positioned: .below, relativeTo: nil)
            preview = editor
            previewStore = s
        }
        if let row = rows[safe: i] { listBody.scrollToVisible(row.frame) }
        needsLayout = true
    }

    /// "Today 10:42", "Yesterday 10:42", else "23 Oct 10:42".
    static func when(_ ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_AU")
        f.dateFormat = "H:mm"
        let time = f.string(from: date)
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "Today " + time }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday " + time }
        f.setLocalizedDateFormatFromTemplate(cal.isDate(date, equalTo: now, toGranularity: .year) ? "dMMM" : "dMMMy")
        return f.string(from: date) + " " + time
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose()
        case 125: if let i = selected, i + 1 < versions.count { select(i + 1) }
        case 126: if let i = selected, i > 0 { select(i - 1) }
        default: super.keyDown(with: event)
        }
    }

    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        layer?.backgroundColor = Themed.color(\.background).cgColor(in: self)
        rule.backgroundColor = Themed.color(\.border).cgColor(in: self)
    }

    public override func layout() {
        super.layout()
        let side = Self.sideWidth
        let left = max(0, bounds.width - side)
        rule.frame = NSRect(x: left, y: 0, width: 1, height: bounds.height)
        heading.frame = NSRect(x: left + 20, y: 56, width: side - 40, height: 20)
        note.frame = NSRect(x: left + 20, y: 78, width: side - 40, height: 20)
        let r = restore.intrinsicContentSize, c = close.intrinsicContentSize
        let by = bounds.height - 20 - r.height
        restore.frame = NSRect(x: left + 20, y: by, width: r.width, height: r.height)
        close.frame = NSRect(x: bounds.width - 20 - c.width, y: by, width: c.width, height: c.height)
        list.frame = NSRect(x: left + 1, y: 110, width: side - 1, height: max(0, by - 16 - 110))
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 8, y: y, width: side - 17, height: 48)
            y += 50
        }
        listBody.frame = NSRect(x: 0, y: 0, width: side - 1, height: max(y, list.contentSize.height))
        if let preview {
            let column = min(SpacePageMetrics.column, max(240, left - 64))
            let x = ((left - column) / 2).rounded()
            preview.scrollView.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
            let inset = NSSize(width: x, height: 150)
            let tv = preview.textView
            if tv.textContainerInset != inset { tv.textContainerInset = inset; preview.columnWidthChanged() }
            previewMeta.frame = NSRect(x: x, y: 56, width: column, height: 20)
            previewTitle.frame = NSRect(x: x, y: 80, width: column, height: 42)
        }
    }
}

final class SpaceVersionRowView: DSView {
    let when = LabelView("", font: DSFont.ui(13, weight: .medium), color: Themed.color(\.foreground))
    let detail = LabelView("", font: DSFont.ui(12), color: Themed.color(\.mutedForeground))
    var onPress: () -> Void = {}
    var isSelected = false { didSet { if isSelected != oldValue { restyle() } } }
    private var hovering = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        when.lineHeight = 18
        detail.lineHeight = 16
        [when, detail].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        setAccessibilityLabel(when.text + ", " + detail.text)
        setAccessibilitySelected(isSelected)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = isSelected ? Themed.color(\.secondary).cgColor(in: self)
            : hovering ? Themed.color(\.muted).cgColor(in: self) : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        when.frame = NSRect(x: 12, y: 7, width: bounds.width - 24, height: 18)
        detail.frame = NSRect(x: 12, y: 25, width: bounds.width - 24, height: 16)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}

final class SpaceFlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
