import AppKit
import DesignSystem
import SpaceEngine
import SpaceModel

/// A Space page's tab (docs/space.md section 4): the header with breadcrumb, title, edited line and the view switch,
/// over the page's current view. Page view is the editor; Board, Table and Timetable slot in through `content(for:)`
/// as pieces 13 to 15 land. "No pages yet" shows with a New page button when there is no page to open.
public final class SpacePageView: DSView {
    public let store: SpaceDocumentStore
    public weak var blobs: SpaceBlobSource?
    public var onNewPage: () -> Void = {}
    public var onOpenPage: (PageID) -> Void = { _ in }
    public private(set) var page: PageID?
    private(set) var editor: SpacePageEditor?
    private var stub: NSView?
    private(set) var history: SpacePageHistoryView?
    private var shownView: ViewType?
    let header = SpacePageHeaderView()
    private let emptyTitle = LabelView("No pages yet", font: DSFont.ui(32, weight: .semibold), color: Themed.color(\.mutedForeground))
    private let newPage = ButtonView("New page", icon: .plus, variant: .secondary, size: .sm)
    private var token: Int?
    private var laidOutWidth: CGFloat?

    public init(store: SpaceDocumentStore, blobs: SpaceBlobSource? = nil) {
        self.store = store
        self.blobs = blobs
        super.init(frame: .zero)
        emptyTitle.lineHeight = 40
        [emptyTitle, newPage].forEach(addSubview)
        newPage.action = { [weak self] in self?.onNewPage() }
        header.onTitle = { [weak self] title in
            guard let self, let page = self.page else { return }
            self.store.rename(page, title)
        }
        header.onTitleReturn = { [weak self] in
            guard let tv = self?.editor?.textView else { return }
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        header.viewSwitch.onSelect = { [weak self] view in self?.setView(view) }
        header.onHistory = { [weak self] in self?.showHistory() }
        header.onIcon = { [weak self] anchor in self?.pickIcon(anchor) }
        token = store.observe { [weak self] in self?.storeChanged() }
        show(nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit { if let token { store.removeObserver(token) } }

    /// Sends typing that's still waiting for its 400 ms flush, before Space closes or the app quits.
    public func commitTyping() { editor?.flushTyping() }

    /// Leaving the window, for another tab, Trash or Space turning off, sends waiting typing before the editor can go.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { commitTyping() }
        super.viewWillMove(toWindow: newWindow)
    }

    public func show(_ id: PageID?) {
        let changed = id != page
        page = id
        if changed { editor?.flushTyping(); clearContent() }
        refresh()
        if changed, let id, store.pages[id]?.title.isEmpty == true { header.focusTitle() }
    }

    /// Page history over the tab, from the header's history button or the sidebar's ⋯ menu.
    public func showHistory() {
        guard let page, history == nil else { return }
        editor?.flushTyping()
        let view = SpacePageHistoryView(store: store, page: page, blobs: blobs)
        view.onClose = { [weak self] in self?.closeHistory() }
        view.onRestore = { [weak self] version in self?.restore(version) }
        addSubview(view)
        history = view
        needsLayout = true
        window?.makeFirstResponder(view)
    }

    func closeHistory() {
        history?.removeFromSuperview()
        history = nil
        if let tv = editor?.textView { window?.makeFirstResponder(tv) }
    }

    /// One change through the apply path, so it syncs like any edit. In Page view it joins the editor's undo stack.
    func restore(_ version: SpaceVersion) {
        let changes = store.restoreChanges(version)
        closeHistory()
        guard !changes.isEmpty else { return }
        if let editor {
            editor.commitDiscrete(changes, name: "Restore Version")
            editor.load(keepSelection: true)
        } else {
            store.edit(changes)
        }
    }

    /// In Page view the change joins the editor's undo stack, like a restore.
    private func pickIcon(_ anchor: NSRect) {
        guard let page else { return }
        SpacePageIcon.showPicker(from: header, anchor: anchor, current: store.pages[page]) { [weak self] choice in
            guard let self, self.page == page else { return }
            let change = SpacePageIcon.change(page, choice)
            if let editor = self.editor { editor.commitDiscrete([change], name: "Icon") } else { self.store.edit([change]) }
        }
    }

    private func clearContent() {
        editor?.flushTyping()
        history?.removeFromSuperview()
        history = nil
        editor?.scrollView.removeFromSuperview()
        editor = nil
        laidOutWidth = nil
        stub?.removeFromSuperview()
        stub = nil
        header.removeFromSuperview()
        shownView = nil
    }

    private func storeChanged() {
        guard let page else { return }
        if store.pages[page] == nil { show(nil); return }
        refresh()
    }

    private func refresh() {
        let pages = store.pages
        guard let page, let record = pages[page] else {
            clearContent()
            emptyTitle.isHidden = false
            newPage.isHidden = false
            setAccessibilityLabel("No pages yet")
            needsLayout = true
            return
        }
        emptyTitle.isHidden = true
        newPage.isHidden = true
        let names = SpaceTree.ancestors(of: page, in: pages).map { pages[$0].map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled" }
        header.update(crumb: ["Space"] + names, title: record.title, meta: meta(page, record), view: record.view)
        header.icon = SpacePageIcon.choice(record)
        setAccessibilityLabel(record.title.isEmpty ? "Untitled" : record.title)
        if shownView != record.view { mount(record.view) }
        needsLayout = true
    }

    /// Board, Table and Timetable register here, one line each. A view type without an entry shows the stub.
    /// Each view gets the store, the page and this tab, whose `header` lands on top of it after it's made.
    static let itemViews: [ViewType: @MainActor (SpaceDocumentStore, PageID, SpacePageView) -> NSView] = [
        .board: SpaceBoardView.make,
        .table: SpaceTableView.make,
    ]

    private func mount(_ view: ViewType) {
        guard let page else { return }
        clearContent()
        shownView = view
        if view == .page {
            let editor = SpacePageEditor(store: store, page: page, blobs: blobs)
            editor.onOpenPage = { [weak self] id in self?.onOpenPage(id) }
            editor.textView.addSubview(header)
            addSubview(editor.scrollView)
            self.editor = editor
        } else {
            let stub = Self.itemViews[view]?(store, page, self) ?? SpaceViewStub(view: view)
            stub.addSubview(header)
            if view == .timetable { SpaceTimetableView.install(in: stub, header: header, store: store, page: page) { [weak self] in self?.onOpenPage($0) } }
            addSubview(stub)
            self.stub = stub
        }
    }

    private func setView(_ view: ViewType) {
        guard let page, var record = store.pages[page], record.view != view else { return }
        editor?.flushTyping()
        record.view = view
        store.put([page: record])
    }

    /// "Edited today at 9:14", and for a to-do list "5 to-dos, 1 overdue".
    private func meta(_ page: PageID, _ record: PageRecord) -> (edited: String?, counts: String?) {
        var edited: String?
        if let at = store.edited[page] {
            let date = Date(timeIntervalSince1970: TimeInterval(at) / 1000)
            let time = DateFormatter()
            time.locale = Locale(identifier: "en_AU")
            time.dateFormat = "H:mm"
            if Calendar.current.isDateInToday(date) { edited = "today at " + time.string(from: date) }
            else if Calendar.current.isDateInYesterday(date) { edited = "yesterday at " + time.string(from: date) }
            else {
                let day = DateFormatter()
                day.locale = Locale(identifier: "en_AU")
                day.setLocalizedDateFormatFromTemplate("dMMM")
                edited = day.string(from: date)
            }
        }
        guard record.isTodoList else { return (edited, nil) }
        let items = store.content(of: page).compactMap { c -> PageRecord? in if case .page(_, let r) = c { r } else { nil } }
        let todos = items.filter { $0.props[FieldID.done] != nil }
        let open = todos.filter { if case .checkbox(true)? = $0.props[FieldID.done] { false } else { true } }
        let late = open.filter { r in
            guard case .date(let due)? = r.props[FieldID.due] else { return false }
            var p = SpaceParagraph()
            p.due = due
            return SpacePageEditor.dueText(p)?.late ?? false
        }.count
        let count = open.count == 1 ? "1 to-do" : "\(open.count) to-dos"
        return (edited, late > 0 ? "\(count), \(late) overdue" : count)
    }

    public override func layout() {
        super.layout()
        let column = min(SpacePageMetrics.column, max(240, bounds.width - 64))
        let x = ((bounds.width - column) / 2).rounded()
        emptyTitle.frame = NSRect(x: x, y: 96, width: column, height: 40)
        let s = newPage.intrinsicContentSize
        newPage.frame = NSRect(x: x, y: 156, width: s.width, height: s.height)
        history?.frame = bounds
        let h = header.height
        if let editor {
            editor.scrollView.frame = bounds
            let tv = editor.textView
            let inset = NSSize(width: x, height: h)
            if tv.textContainerInset != inset { tv.textContainerInset = inset }
            if tv.textContainer?.size.width != laidOutWidth {
                laidOutWidth = tv.textContainer?.size.width
                editor.columnWidthChanged()
            }
            header.frame = NSRect(x: x, y: 0, width: column, height: h)
        } else if let stub {
            // Board, Table and Timetable use the full width, so their header does too.
            stub.frame = bounds
            header.frame = NSRect(x: 32, y: 0, width: max(0, bounds.width - 64), height: h)
        }
    }
}

/// Breadcrumb, title, edited line and the view switch, look B of the page mockup.
final class SpacePageHeaderView: DSView, NSTextFieldDelegate {
    let height: CGFloat = 186
    /// The placeholder's line box sits a point above the field's: LabelView centers the line in its box, a point lower
    /// than the field draws it, so at 2x the placeholder covers the typed title's pixels exactly.
    static let placeholderDrop: CGFloat = -1
    private let crumb = LabelView("", font: DSFont.ui(12), color: Themed.color(\.secondaryLabel))
    private let title = NSTextField()
    /// "Untitled" while the title is empty, also while it's being edited. The header lays it out on the line the typed
    /// title takes; AppKit's own placeholder drew half a line high on the user's Mac, over the breadcrumb.
    private let placeholder = LabelView("Untitled", font: DSFont.ui(34, weight: .semibold), color: Themed.color(\.placeholder))
    private let meta = NSTextField(labelWithString: "")
    let viewSwitch = SpaceViewSwitch()
    let historyButton = ButtonView(icon: .history, variant: .ghost, size: .iconSm)
    let iconView = SpaceIconView()
    let addIconButton = ButtonView(icon: .smilePlus, variant: .ghost, size: .iconSm)
    var icon: SpacePageIcon.Choice = .none {
        didSet { if icon != oldValue { iconView.choice = icon; addIconButton.isHidden = icon != .none; needsLayout = true } }
    }
    /// Opens the icon picker under the given rect.
    var onIcon: (NSRect) -> Void = { _ in }
    var onHistory: () -> Void = {}
    var onTitle: (String) -> Void = { _ in }
    var onTitleReturn: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        crumb.lineHeight = 16
        title.isBordered = false
        title.drawsBackground = false
        title.focusRingType = .none
        title.font = DSFont.ui(34, weight: .semibold)
        title.textColor = Themed.color(\.foreground)
        title.setAccessibilityPlaceholderValue("Untitled")
        title.clipsToBounds = true
        placeholder.lineHeight = 42
        title.lineBreakMode = .byTruncatingTail
        title.cell?.usesSingleLineMode = true
        title.delegate = self
        title.setAccessibilityLabel("Page title")
        meta.font = DSFont.ui(12)
        historyButton.setAccessibilityLabel("Page history")
        historyButton.toolTip = "Page history"
        historyButton.iconColor = Themed.color(\.mutedForeground)
        historyButton.action = { [weak self] in self?.onHistory() }
        iconView.setAccessibilityLabel("Page icon")
        iconView.toolTip = "Change icon"
        iconView.onClick = { [weak self] in guard let self else { return }; self.onIcon(self.iconView.frame) }
        addIconButton.setAccessibilityLabel("Add icon")
        addIconButton.toolTip = "Add icon"
        addIconButton.iconColor = Themed.color(\.mutedForeground)
        addIconButton.action = { [weak self] in guard let self else { return }; self.onIcon(self.addIconButton.frame) }
        [crumb, placeholder, title, meta, viewSwitch, historyButton, iconView, addIconButton].forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func update(crumb names: [String], title text: String, meta m: (edited: String?, counts: String?), view: ViewType) {
        crumb.text = names.joined(separator: "  ›  ")
        if title.currentEditor() == nil, title.stringValue != text { title.stringValue = text }
        placeholder.isHidden = !title.stringValue.isEmpty
        let s = NSMutableAttributedString()
        if let edited = m.edited {
            s.append(NSAttributedString(string: "Edited ", attributes: [.font: DSFont.ui(12, weight: .medium), .foregroundColor: Themed.color(\.mutedForeground)]))
            s.append(NSAttributedString(string: edited, attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.secondaryLabel)]))
        }
        if let counts = m.counts {
            if s.length > 0 { s.append(NSAttributedString(string: "      ")) }
            s.append(NSAttributedString(string: counts, attributes: [.font: DSFont.ui(12), .foregroundColor: Themed.color(\.secondaryLabel)]))
        }
        meta.attributedStringValue = s
        viewSwitch.selected = view
    }

    func focusTitle() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.title)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        placeholder.isHidden = !title.stringValue.isEmpty
        onTitle(title.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            onTitleReturn()
            return true
        }
        return false
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        crumb.frame = NSRect(x: 0, y: 56, width: w, height: 16)
        let switchSize = viewSwitch.intrinsicContentSize
        viewSwitch.frame = NSRect(x: w - switchSize.width, y: 80 + (42 - switchSize.height) / 2, width: switchSize.width, height: switchSize.height)
        let hb = historyButton.intrinsicContentSize
        historyButton.frame = NSRect(x: viewSwitch.frame.minX - 8 - hb.width, y: 80 + (42 - hb.height) / 2, width: hb.width, height: hb.height)
        addIconButton.frame = historyButton.frame.offsetBy(dx: -hb.width - 2, dy: 0)
        // A set icon sits before the title at its cap height; the title moves over by its width.
        iconView.frame = NSRect(x: -4, y: 81, width: 40, height: 40)
        let tx: CGFloat = iconView.isHidden ? -2 : 44
        let right = addIconButton.isHidden ? historyButton.frame.minX : addIconButton.frame.minX
        title.frame = NSRect(x: tx, y: 80, width: max(0, right - 12 - tx), height: 42)
        placeholder.frame = NSRect(x: tx + 2, y: 80 + Self.placeholderDrop, width: title.frame.width, height: 42)
        meta.frame = NSRect(x: 0, y: 134, width: w, height: 16)
    }
}

/// Page, Board, Table and Timetable as one toggle group with icons. The choice is the page's `view` and syncs.
final class SpaceViewSwitch: DSView {
    var onSelect: (ViewType) -> Void = { _ in }
    var selected: ViewType = .page { didSet { if selected != oldValue { updateSegments() } } }
    private var segments: [(view: ViewType, button: SpaceSwitchSegment)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (view, title) in [(ViewType.page, "Page"), (.board, "Board"), (.table, "Table"), (.timetable, "Timetable")] {
            let b = SpaceSwitchSegment(title: title, icon: SpacePageIcons.viewIcon(view))
            b.onPress = { [weak self] in self?.onSelect(view) }
            addSubview(b)
            segments.append((view, b))
        }
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("View")
        updateSegments()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func updateSegments() { for s in segments { s.button.isOn = s.view == selected } }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segments.reduce(2) { $0 + $1.button.intrinsicContentSize.width + 2 }, height: 28)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = Themed.color(\.muted).cgColor(in: self)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        for s in segments {
            let w = s.button.intrinsicContentSize.width
            s.button.frame = NSRect(x: x, y: 2, width: w, height: 24)
            x += w + 2
        }
    }
}

final class SpaceSwitchSegment: DSView {
    var onPress: () -> Void = {}
    var isOn = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    private let icon: IconView
    private let label: LabelView

    init(title: String, icon name: IconName) {
        icon = IconView(name: name, size: 14, strokeColor: Themed.color(\.mutedForeground))
        label = LabelView(title, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        label.lineHeight = 16
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 9 + 14 + 6 + label.textWidth.rounded(.up) + 9, height: 24) }

    private func restyle() {
        let color = isOn || hovering ? Themed.color(\.foreground) : Themed.color(\.mutedForeground)
        label.color = color
        icon.strokeColor = color
        setAccessibilityValue(isOn)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = isOn ? Themed.color(\.secondary).cgColor(in: self) : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 9, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 29, y: (bounds.height - 16) / 2, width: bounds.width - 29 - 9, height: 16)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress() }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
}

/// Board, Table and Timetable until pieces 13 to 15: the header, the quiet Filter, Sort and Fields row, and a note.
final class SpaceViewStub: DSView {
    let view: ViewType
    private let note: LabelView
    private let tools = ["Filter", "Sort", "Fields"].map { LabelView($0, font: DSFont.ui(12, weight: .medium), color: Themed.color(\.placeholder)) }

    init(view: ViewType) {
        self.view = view
        let name = view == .board ? "Board" : view == .table ? "Table" : "Timetable"
        note = LabelView("\(name) view isn't built yet. Switch to Page to edit this page.", font: DSFont.ui(13), color: Themed.color(\.mutedForeground))
        super.init(frame: .zero)
        note.lineHeight = 20
        addSubview(note)
        tools.forEach { $0.lineHeight = 16; addSubview($0) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let column = min(SpacePageMetrics.column, max(240, bounds.width - 64))
        let x = ((bounds.width - column) / 2).rounded()
        var tx = x
        for t in tools {
            let w = t.textWidth.rounded(.up)
            t.frame = NSRect(x: tx, y: 168, width: w, height: 16)
            tx += w + 20
        }
        note.frame = NSRect(x: x, y: 216, width: column, height: 20)
    }
}
